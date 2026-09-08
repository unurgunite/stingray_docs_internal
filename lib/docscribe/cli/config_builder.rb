# frozen_string_literal: true

require 'docscribe/config'

module Docscribe
  module CLI
    # Build and override effective config from CLI flags.
    module ConfigBuilder
      module_function

      # Build an effective config by applying CLI overrides on top of a base config.
      #
      # CLI overrides currently affect:
      # - method/file include and exclude filters
      # - RBS enablement and additional signature directories
      # - Sorbet enablement and RBI directories
      #
      # If no relevant CLI override is present, the original config is returned unchanged.
      #
      # @note module_function: defines #build (visibility: private)
      # @param [Docscribe::Config] base base config loaded from YAML/defaults
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [Docscribe::Config] merged effective config
      def build(base, options)
        return base unless needs_override?(options)

        raw = Marshal.load(Marshal.dump(base.raw))
        apply_filter_overrides(raw, options)
        apply_rbs_overrides(raw, options) if rbs_overrides?(options)
        apply_sorbet_overrides(raw, options) if sorbet_overrides?(options)
        apply_output_overrides(raw, options)
        apply_validation_overrides(raw, options) if validation_overrides?(options)
        conf = Docscribe::Config.new(config_path: base.config_path, **raw)
        warn_missing_rbs_collection(conf, options)
        conf
      end

      # Whether any CLI override is present.
      #
      # @note module_function: defines #needs_override? (visibility: private)
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [Boolean]
      def needs_override?(options)
        filter_overrides?(options) ||
          rbs_overrides?(options) ||
          sorbet_overrides?(options) ||
          output_overrides?(options) ||
          validation_overrides?(options)
      end

      # Whether any method or file filter CLI options were provided.
      #
      # @note module_function: defines #filter_overrides? (visibility: private)
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [Boolean]
      def filter_overrides?(options)
        options[:include].any? ||
          options[:exclude].any?      ||
          options[:include_file].any? ||
          options[:exclude_file].any?
      end

      # Apply method and file filter overrides to the raw config.
      #
      # @note module_function: defines #apply_filter_overrides (visibility: private)
      # @param [Hash<String, Object>] raw raw config hash
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [void]
      def apply_filter_overrides(raw, options)
        apply_method_filters(raw, options)
        apply_file_filters(raw, options)
      end

      # Whether any RBS-related CLI options were provided.
      #
      # @note module_function: defines #rbs_overrides? (visibility: private)
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [Boolean]
      def rbs_overrides?(options)
        options[:rbs] ||
          options[:rbs_collection] ||
          options[:sig_dirs].any?
      end

      # Merge CLI method include/exclude patterns into the raw config hash.
      #
      # @note module_function: defines #apply_method_filters (visibility: private)
      # @param [Hash<String, Object>] raw raw config hash
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [void]
      def apply_method_filters(raw, options)
        raw['filter'] ||= {}
        raw['filter']['include'] = Array(raw['filter']['include']) + options[:include]
        raw['filter']['exclude'] = Array(raw['filter']['exclude']) + options[:exclude]
      end

      # Merge CLI file include/exclude patterns into the raw config hash.
      #
      # @note module_function: defines #apply_file_filters (visibility: private)
      # @param [Hash<String, Object>] raw raw config hash
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [void]
      def apply_file_filters(raw, options)
        files = raw['filter']['files']
        if files.nil?
          files = {} #: Hash[String, untyped]
          raw['filter']['files'] = files
        end

        files['include'] = Array(files['include']) + options[:include_file]
        files['exclude'] = Array(files['exclude']) + options[:exclude_file]
        files
      end

      # Apply RBS-related CLI overrides to the raw config.
      #
      # @note module_function: defines #apply_rbs_overrides (visibility: private)
      # @param [Hash<String, Object>] raw raw config hash
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [void]
      def apply_rbs_overrides(raw, options)
        raw['rbs'] ||= {}
        raw['rbs']['enabled'] = true
        raw['rbs']['sig_dirs'] = Array(raw['rbs']['sig_dirs']) + options[:sig_dirs] if options[:sig_dirs].any?

        return unless options[:rbs_collection]

        apply_rbs_collection(raw)
      end

      # Whether any Sorbet-related CLI options were provided.
      #
      # @note module_function: defines #sorbet_overrides? (visibility: private)
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [Boolean]
      def sorbet_overrides?(options)
        options[:sorbet] ||
          options[:rbi_dirs].any?
      end

      # Resolve and apply the RBS collection path into the raw config hash.
      #
      # @note module_function: defines #apply_rbs_collection (visibility: private)
      # @param [Hash<String, Object>] raw raw config hash
      # @return [void]
      def apply_rbs_collection(raw)
        require 'docscribe/types/rbs/collection_loader'
        collection_path = Docscribe::Types::RBS::CollectionLoader.resolve
        if collection_path
          raw['rbs']['collection_dirs'] = Array(raw['rbs']['collection_dirs']) + [collection_path]
        else
          warn 'Docscribe: rbs_collection.lock.yaml not found. ' \
               'Run `bundle exec rbs collection install` first.'
        end
      end

      # Apply Sorbet-related CLI overrides to the raw config.
      #
      # @note module_function: defines #apply_sorbet_overrides (visibility: private)
      # @param [Hash<String, Object>] raw raw config hash
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [void]
      def apply_sorbet_overrides(raw, options)
        raw['sorbet'] ||= {}
        raw['sorbet']['enabled'] = true
        return unless options[:rbi_dirs].any?

        raw['sorbet']['rbi_dirs'] = Array(raw['sorbet']['rbi_dirs']) + options[:rbi_dirs]
      end

      # Whether any output-related CLI options were provided.
      #
      # @note module_function: defines #output_overrides? (visibility: private)
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [Boolean]
      def output_overrides?(options)
        !!options[:keep_descriptions] || !!options[:no_boilerplate]
      end

      # Apply output-related CLI overrides to the raw config.
      #
      # Currently handles:
      # - `keep_descriptions` -> raw['keep_descriptions']
      # - `no_boilerplate` -> raw['emit']['include_default_message'] and
      #   raw['emit']['include_param_documentation'] = false
      #
      # @note module_function: defines #apply_output_overrides (visibility: private)
      # @param [Hash<String, Object>] raw raw config hash
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [void]
      def apply_output_overrides(raw, options)
        return unless options[:keep_descriptions] || options[:no_boilerplate]

        raw['keep_descriptions'] = true if options[:keep_descriptions]
        raw['emit'] ||= {}
        raw['emit']['include_default_message'] = false if options[:no_boilerplate]
        raw['emit']['include_param_documentation'] = false if options[:no_boilerplate]
      end

      # Whether any validation-related CLI options were provided.
      #
      # @note module_function: defines #validation_overrides? (visibility: private)
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [Boolean]
      def validation_overrides?(options)
        !!options[:validate_types]
      end

      # Apply validation-related CLI overrides to the raw config.
      #
      # @note module_function: defines #apply_validation_overrides (visibility: private)
      # @param [Hash<String, Object>] raw raw config hash
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [void]
      def apply_validation_overrides(raw, options)
        raw['validate_types'] = true if options[:validate_types]
      end

      # Warn when rbs_collection.lock.yaml exists but --rbs-collection was not passed.
      #
      # The warning can be suppressed by setting `rbs.warn_missing_collection: false`
      # in the project's `docscribe.yml`.
      #
      # @note module_function: defines #warn_missing_rbs_collection (visibility: private)
      # @param [Docscribe::Config] conf effective config
      # @param [Hash<Symbol, Object>] options parsed CLI options
      # @return [void]
      def warn_missing_rbs_collection(conf, options)
        return if options[:rbs_collection]
        return if conf.raw.dig('rbs', 'collection')
        return unless conf.rbs_warn_missing_collection?
        return unless File.exist?('rbs_collection.lock.yaml')

        warn 'Docscribe: rbs_collection.lock.yaml found but --rbs-collection not set. ' \
             'Pass --rbs-collection or set `rbs.collection: true` in docscribe.yml to enable RBS collection. ' \
             'Set `rbs.warn_missing_collection: false` to suppress this warning.'
      end
    end
  end
end

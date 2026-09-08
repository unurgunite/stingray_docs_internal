# frozen_string_literal: true

require 'optparse'

module Docscribe
  module CLI
    # CLI option parsing and defaults.
    module Options
      DEFAULT = {
        stdin: false,
        mode: :check,       # :check, :write, :stdin
        strategy: :safe,    # :safe, :aggressive
        verbose: false,
        explain: false,
        quiet: false,
        format: :text,
        config: nil,
        include: [], #: Array[String]
        exclude: [], #: Array[String]
        include_file: [], #: Array[String]
        exclude_file: [], #: Array[String]
        rbs: false,
        sig_dirs: [], #: Array[String]
        sorbet: false,
        rbi_dirs: [], #: Array[String]
        rbs_collection: false,
        keep_descriptions: false,
        no_boilerplate: false,
        progress: false,
        parallel: false,
        server: false,
        validate_types: false
      }.freeze

      module_function

      BANNER = <<~TEXT
        Usage: docscribe [options] [files...]
               docscribe init [options]
               docscribe generate <type> <name> [options]
               docscribe sigs [options] [files...]
               docscribe rbs [options] [files...]
               docscribe update_types [directory|file]
               docscribe check_for_comments [paths...]

        Default behavior:
          Inspect files and report what safe doc updates would be applied.

        Autocorrect:
            -a, --autocorrect              Apply safe doc updates in place
                                           (insert missing docs, merge existing doc-like blocks,
                                           normalize tag order)
            -A, --autocorrect-all          Apply aggressive doc updates in place
                                           (rebuild existing doc blocks)

        Input / config:
                --stdin                    Read code from STDIN and print rewritten output
            -C,                 --config PATH              Path to config YAML (default: docscribe.yml)
                --server                   Use background server for faster repeated runs

        Type information:
                --rbs                      Use RBS signatures for @param/@return when available
                --sig-dir DIR              Add an RBS signature directory (repeatable). Implies `--rbs`.
                --sorbet                   Use Sorbet signatures from inline sigs / RBI files when available
                --rbi-dir DIR              Add a Sorbet RBI directory (repeatable). Implies --sorbet.
                --rbs-collection           Auto-discover RBS collection from rbs_collection.lock.yaml. Implies --rbs.
                --validate-types           Validate YARD types against inferred/RBS types and report mismatches

        Filtering:
                --include PATTERN          Include PATTERN (method id or file path; glob or /regex/)
                --exclude PATTERN          Exclude PATTERN (method id or file path; glob or /regex/)
                --include-file PATTERN     Only process files matching PATTERN (glob or /regex/)
                --exclude-file PATTERN     Skip files matching PATTERN (glob or /regex/)

        Output:
                --verbose                  Print per-file actions
                --progress                 Show progress [N/total] per file
            -e, --explain                  Show detailed reasons for changes (default)
            -q, --quiet                    Only show status, no details
                --format FORMAT            Output format: text (default), json, or sarif

        Performance:
                --parallel                 Process files in parallel (default: sequential)

        Other:
            -v, --version                  Print version and exit
            -h, --help                     Show this help
      TEXT

      # Parse CLI arguments into normalized Docscribe runtime options.
      #
      # CLI behavior model:
      # - default: inspect mode using the safe strategy
      # - `-a` / `--autocorrect`: write mode using the safe strategy
      # - `-A` / `--autocorrect-all`: write mode using the aggressive strategy
      # - `--stdin`: stdin mode using the selected strategy (safe by default)
      #
      # Filtering, config, verbosity, and external type options are applied
      # orthogonally.
      #
      # @note module_function: defines #parse! (visibility: private)
      # @param [Array<String>] argv raw CLI arguments
      # @return [Docscribe::CLI::Formatters::opts] normalized runtime options
      def parse!(argv)
        options = Marshal.load(Marshal.dump(DEFAULT))
        autocorrect = { mode: nil }

        build_option_parser(options, autocorrect).parse!(argv)
        resolve_mode_and_strategy!(options, autocorrect[:mode])
        options
      end

      # Build the OptionParser instance and register all CLI option groups.
      #
      # @note module_function: defines #build_option_parser (visibility: private)
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @param [Hash<Symbol, Symbol, nil>] autocorrect mutable container for autocorrect mode
      # @return [OptionParser]
      def build_option_parser(options, autocorrect)
        OptionParser.new do |opts|
          opts.banner = BANNER
          define_autocorrect_options(opts, autocorrect)
          define_input_options(opts, options)
          define_type_options(opts, options)
          define_filter_options(opts, options)
          define_output_options(opts, options)
          define_misc_options(opts)
        end
      end

      # Define autocorrect options
      #
      # @note module_function: defines #define_autocorrect_options (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Symbol, nil>] autocorrect mutable container for autocorrect mode (:safe, :aggressive, nil)
      # @return [void]
      def define_autocorrect_options(opts, autocorrect)
        opts.on('-a', '--autocorrect', 'Apply safe doc updates in place') do
          autocorrect[:mode] = :safe
        end

        opts.on('-A', '--autocorrect-all', 'Apply aggressive doc updates in place') do
          autocorrect[:mode] = :aggressive
        end
      end

      # Define input options
      #
      # @note module_function: defines #define_input_options (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_input_options(opts, options)
        define_stdin_option(opts, options)
        define_config_option(opts, options)
        define_server_option(opts, options)
      end

      # Define stdin option
      #
      # @note module_function: defines #define_stdin_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_stdin_option(opts, options)
        opts.on('--stdin', 'Read code from STDIN and print rewritten output') do
          options[:stdin] = true
        end
      end

      # Define config option
      #
      # @note module_function: defines #define_config_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_config_option(opts, options)
        opts.on('-C', '--config PATH', 'Path to config YAML (default: docscribe.yml)') do |v|
          options[:config] = v
        end
      end

      # Define server option
      #
      # @note module_function: defines #define_server_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_server_option(opts, options)
        opts.on('--server', 'Use background server for faster repeated runs') do
          options[:server] = true
        end
      end

      # Define type options
      #
      # @note module_function: defines #define_type_options (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_type_options(opts, options)
        define_rbs_option(opts, options)
        define_sig_dir_option(opts, options)
        define_sorbet_option(opts, options)
        define_rbi_dir_option(opts, options)
        define_rbs_collection_option(opts, options)
        define_validate_types_option(opts, options)
      end

      # Define rbs option
      #
      # @note module_function: defines #define_rbs_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_rbs_option(opts, options)
        opts.on('--rbs', 'Use RBS signatures for @param/@return when available (falls back to inference)') do
          options[:rbs] = true
        end
      end

      # Define sig dir option
      #
      # @note module_function: defines #define_sig_dir_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_sig_dir_option(opts, options)
        opts.on('--sig-dir DIR', 'Add an RBS signature directory (repeatable). Implies --rbs.') do |v|
          options[:rbs] = true
          options[:sig_dirs] << v
        end
      end

      # Define sorbet option
      #
      # @note module_function: defines #define_sorbet_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_sorbet_option(opts, options)
        opts.on('--sorbet', 'Use Sorbet signatures from inline sigs / RBI files when available') do
          options[:sorbet] = true
        end
      end

      # Define rbi dir option
      #
      # @note module_function: defines #define_rbi_dir_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_rbi_dir_option(opts, options)
        opts.on('--rbi-dir DIR', 'Add a Sorbet RBI directory (repeatable). Implies --sorbet.') do |v|
          options[:sorbet] = true
          options[:rbi_dirs] << v
        end
      end

      # Define rbs collection option
      #
      # @note module_function: defines #define_rbs_collection_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_rbs_collection_option(opts, options)
        opts.on('--rbs-collection', 'Auto-discover RBS collection from rbs_collection.lock.yaml. Implies --rbs.') do
          options[:rbs] = true
          options[:rbs_collection] = true
        end
      end

      # Define validate types option
      #
      # @note module_function: defines #define_validate_types_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_validate_types_option(opts, options)
        opts.on('--[no-]validate-types', 'Validate YARD types against inferred/RBS types and report mismatches') do |value|
          options[:validate_types] = value
        end
      end

      # Define filter options
      #
      # @note module_function: defines #define_filter_options (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_filter_options(opts, options)
        define_include_option(opts, options)
        define_exclude_option(opts, options)
        define_include_file_option(opts, options)
        define_exclude_file_option(opts, options)
      end

      # Define include option
      #
      # @note module_function: defines #define_include_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_include_option(opts, options)
        opts.on('--include PATTERN', 'Include PATTERN (method id or file path; glob or /regex/)') do |v|
          route_include_exclude(options, :include, v)
        end
      end

      # Define exclude option
      #
      # @note module_function: defines #define_exclude_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_exclude_option(opts, options)
        opts.on('--exclude PATTERN',
                'Exclude PATTERN (method id or file path; glob or /regex/). Exclude wins.') do |v|
          route_include_exclude(options, :exclude, v)
        end
      end

      # Define include file option
      #
      # @note module_function: defines #define_include_file_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_include_file_option(opts, options)
        opts.on('--include-file PATTERN', 'Only process files matching PATTERN (glob or /regex/)') do |v|
          options[:include_file] << v
        end
      end

      # Define exclude file option
      #
      # @note module_function: defines #define_exclude_file_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_exclude_file_option(opts, options)
        opts.on('--exclude-file PATTERN', 'Skip files matching PATTERN (glob or /regex/). Exclude wins.') do |v|
          options[:exclude_file] << v
        end
      end

      # Define output options
      #
      # @note module_function: defines #define_output_options (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_output_options(opts, options)
        define_verbose_option(opts, options)
        define_progress_option(opts, options)
        define_parallel_option(opts, options)
        define_explain_option(opts, options)
        define_quiet_option(opts, options)
        define_format_option(opts, options)
        define_keep_descriptions_option(opts, options)
        define_no_boilerplate_option(opts, options)
      end

      # Define verbose option
      #
      # @note module_function: defines #define_verbose_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_verbose_option(opts, options)
        opts.on('--verbose', 'Print per-file actions') do
          options[:verbose] = true
          options[:progress] = true
        end
      end

      # Define progress option
      #
      # @note module_function: defines #define_progress_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_progress_option(opts, options)
        opts.on('--progress', 'Show progress [N/total] per file') do
          options[:progress] = true
        end
      end

      # Define parallel option
      #
      # @note module_function: defines #define_parallel_option (visibility: private)
      # @param [Hash<Symbol, Object>] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_parallel_option(opts, options)
        opts.on('--parallel', 'Process files in parallel (default: sequential)') do
          options[:parallel] = true
        end
      end

      # Define explain option
      #
      # @note module_function: defines #define_explain_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_explain_option(opts, options)
        opts.on('-e', '--explain', 'Show detailed reasons for changes') do
          options[:explain] = true
        end
      end

      # Define quiet option
      #
      # @note module_function: defines #define_quiet_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_quiet_option(opts, options)
        opts.on('-q', '--quiet', 'Only show status, no details') do
          options[:quiet] = true
        end
      end

      # Define format option
      #
      # @note module_function: defines #define_format_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_format_option(opts, options)
        opts.on('--format FORMAT', %i[text json sarif], # steep:ignore
                'Output format: text (default), json, or sarif') do |v|
          options[:format] = v
        end
      end

      # Define keep descriptions option
      #
      # @note module_function: defines #define_keep_descriptions_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_keep_descriptions_option(opts, options)
        opts.on('-k', '--keep-descriptions',
                'Preserve existing @param/@return descriptions in aggressive mode') do
          options[:keep_descriptions] = true
        end
      end

      # Define no boilerplate option
      #
      # @note module_function: defines #define_no_boilerplate_option (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @return [void]
      def define_no_boilerplate_option(opts, options)
        opts.on('-B', '--no-boilerplate',
                "Don't insert template text when generating documentation") do
          options[:no_boilerplate] = true
        end
      end

      # Define misc options
      #
      # @note module_function: defines #define_misc_options (visibility: private)
      # @param [OptionParser] opts the option parser to configure
      # @return [void]
      def define_misc_options(opts)
        opts.on('-v', '--version', 'Print version and exit') do
          require 'docscribe/version'
          puts Docscribe::VERSION
          exit 0
        end

        opts.on('-h', '--help', 'Show this help') do
          puts opts
          exit 0
        end
      end

      # Set the runtime mode and strategy after all options have been parsed.
      #
      # @note module_function: defines #resolve_mode_and_strategy! (visibility: private)
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @param [Symbol, nil] autocorrect_mode autocorrect mode selected (:safe, :aggressive, or nil)
      # @return [void]
      def resolve_mode_and_strategy!(options, autocorrect_mode)
        if options[:stdin]
          options[:mode] = :stdin
          options[:strategy] = autocorrect_mode || :safe
        elsif autocorrect_mode
          options[:mode] = :write
          options[:strategy] = autocorrect_mode
        else
          options[:mode] = :check
          options[:strategy] = :safe
        end
      end

      # Route an include/exclude pattern into method filters or file filters.
      #
      # Regex-looking patterns (`/…/`) are treated as method-id filters.
      # File-like patterns are routed into `*_file`.
      #
      # @note module_function: defines #route_include_exclude (visibility: private)
      # @param [Hash<Symbol, Object>] options mutable parsed options hash
      # @param [Symbol] kind either :include or :exclude
      # @param [String] value raw pattern from the CLI
      # @return [void]
      def route_include_exclude(options, kind, value)
        if looks_like_file_pattern?(value)
          options[:"#{kind}_file"] << value
        else
          options[kind] << value
        end
      end

      # Heuristically decide whether a pattern looks like a file path or file glob.
      #
      # Regex syntax (`/.../`) is intentionally treated as a method-id pattern,
      # not a file pattern.
      #
      # @note module_function: defines #looks_like_file_pattern? (visibility: private)
      # @param [String] pat pattern passed via CLI
      # @return [Boolean]
      def looks_like_file_pattern?(pat)
        return false if pat.start_with?('/') && pat.end_with?('/') && pat.length >= 2
        return false if pat.match?(%r{\A\*/})

        pat.include?('/') || pat.include?('**') || pat.end_with?('.rb')
      end
    end
  end
end

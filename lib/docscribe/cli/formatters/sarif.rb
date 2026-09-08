# frozen_string_literal: true

require 'json'
require 'docscribe/version'

module Docscribe
  module CLI
    module Formatters
      # Output formatter producing SARIF 2.1 JSON.
      #
      # SARIF (Static Analysis Results Interchange Format) is a standard
      # format for static analysis tools. This formatter produces output
      # compatible with GitHub Code Scanning, VS Code SARIF viewer, etc.
      #
      # stdout: complete SARIF 2.1 document with all findings.
      # stderr: progress markers only (same as text mode).
      class Sarif
        SEVERITY_MAP = {
          missing_param: 'note',
          missing_return: 'note',
          missing_raise: 'note',
          missing_visibility: 'note',
          missing_module_function_note: 'note',
          insert_full_doc_block: 'note',
          unsorted_tags: 'note',
          updated_param: 'warning',
          updated_return: 'warning',
          invalid_type: 'warning'
        }.freeze

        COP_NAME_MAP = {
          missing_param: 'Docscribe/MissingParam',
          missing_return: 'Docscribe/MissingReturn',
          missing_raise: 'Docscribe/MissingRaise',
          missing_visibility: 'Docscribe/MissingVisibility',
          missing_module_function_note: 'Docscribe/MissingModuleFunctionNote',
          insert_full_doc_block: 'Docscribe/MissingDocBlock',
          unsorted_tags: 'Docscribe/UnsortedTags',
          updated_param: 'Docscribe/UpdatedParam',
          updated_return: 'Docscribe/UpdatedReturn',
          invalid_type: 'Docscribe/InvalidType'
        }.freeze

        SARIF_SCHEMA = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/' \
                       'master/Schemata/sarif-schema-2.1.0.json'

        # @param [Docscribe::CLI::Formatters::state] state
        # @param [Docscribe::CLI::Formatters::opts] options
        # @return [void]
        def format_check_summary(state:, options:)
          puts JSON.generate(build_sarif_document(state, options[:format]))
        end

        # @param [Docscribe::CLI::Formatters::state] state
        # @param [Docscribe::CLI::Formatters::opts] options
        # @return [void]
        def format_write_summary(state:, options:)
          puts JSON.generate(build_sarif_document(state, options[:format]))
        end

        private

        # @private
        # @param [Docscribe::CLI::Formatters::state] state
        # @param [Object] _format
        # @return [Hash<String, Symbol, Object>]
        def build_sarif_document(state, _format)
          {
            '$schema' => SARIF_SCHEMA,
            version: '2.1.0',
            runs: [build_run(state)]
          }
        end

        # @private
        # @param [Docscribe::CLI::Formatters::state] state
        # @return [Hash<Symbol, Object>]
        def build_run(state)
          {
            tool: build_tool,
            results: build_results(state),
            invocations: [build_invocation(state)]
          }
        end

        # @private
        # @return [Hash<Symbol, Object>]
        def build_tool
          {
            driver: {
              name: 'docscribe',
              version: Docscribe::VERSION,
              informationUri: 'https://github.com/unurgunite/docscribe'
            }
          }
        end

        # @private
        # @param [Docscribe::CLI::Formatters::state] state
        # @return [Array<Hash<Symbol, Object>>]
        def build_results(state)
          results = [] #: Array[Hash[Symbol, top]]

          append_check_results(state, results)
          append_corrected_results(state, results)
          append_error_results(state, results)

          results
        end

        # @private
        # @param [Docscribe::CLI::Formatters::state] state
        # @param [Array<Hash<Symbol, Object>>] results
        # @return [void]
        def append_check_results(state, results)
          append_changes(state[:fail_paths], state[:fail_changes], results)
          append_changes(state[:type_mismatch_paths], state[:type_mismatch_changes], results, level: 'warning')
        end

        # @private
        # @param [Array<String>] paths
        # @param [Hash<String, Array<Docscribe::CLI::Formatters::change>>] changes_map
        # @param [Array<Hash<Symbol, Object>>] results
        # @param [String?] level
        # @return [void]
        def append_changes(paths, changes_map, results, level: nil)
          paths.each do |path|
            (changes_map[path] || []).each do |change|
              results << build_result(change, path, level: level)
            end
          end
        end

        # @private
        # @param [Docscribe::CLI::Formatters::state] state
        # @param [Array<Hash<Symbol, Object>>] results
        # @return [void]
        def append_corrected_results(state, results)
          state[:corrected_paths].each do |path|
            changes = state[:corrected_changes][path] || []
            changes.each do |change|
              results << build_result(change, path)
            end
          end
        end

        # @private
        # @param [Docscribe::CLI::Formatters::state] state
        # @param [Array<Hash<Symbol, Object>>] results
        # @return [void]
        def append_error_results(state, results)
          state[:error_paths].each do |path|
            msg = state[:error_messages][path] || 'Unknown error'
            results << build_error_result(msg, path)
          end
        end

        # @private
        # @param [Docscribe::CLI::Formatters::change] change
        # @param [String] path
        # @param [String?] level
        # @return [Hash<Symbol, Object>]
        def build_result(change, path, level: nil)
          result = {
            ruleId: cop_name_for(change),
            level: level || SEVERITY_MAP[change[:type]] || 'note',
            message: { text: message_for(change) },
            locations: [location(path, change[:line] || 1)]
          }
          source = change[:source] || change['source'] # steep:ignore
          result[:properties] = { source: source } if source
          result
        end

        # @private
        # @param [String] message
        # @param [String] path
        # @return [Hash<Symbol, Object>]
        def build_error_result(message, path)
          {
            ruleId: 'Docscribe/ProcessingError',
            level: 'error',
            message: { text: message },
            locations: [location(path, 1)]
          }
        end

        # @private
        # @param [String] path
        # @param [Integer] line
        # @return [Hash<Symbol, Object>]
        def location(path, line)
          {
            physicalLocation: {
              artifactLocation: { uri: path },
              region: { startLine: line }
            }
          }
        end

        # @private
        # @param [Docscribe::CLI::Formatters::change] change
        # @return [String]
        def cop_name_for(change)
          COP_NAME_MAP[change[:type]] || fallback_cop_name(change)
        end

        # @private
        # @param [Docscribe::CLI::Formatters::change] change
        # @return [String]
        def fallback_cop_name(change)
          name = change[:type].to_s.tr('_', ' ').split.map(&:capitalize).join
          "Docscribe/#{name}"
        end

        # @private
        # @param [Docscribe::CLI::Formatters::change] change
        # @return [String]
        def message_for(change)
          method = change[:method] ? " for #{change[:method]}" : ''
          line = change[:line] ? " at line #{change[:line]}" : ''

          return "unsorted tags#{line}" if change[:type] == :unsorted_tags

          msg = change[:message] || change[:type].to_s.tr('_', ' ')
          "#{msg}#{method}#{line}"
        end

        # @private
        # @param [Docscribe::CLI::Formatters::state] state
        # @return [Hash<Symbol, Object>]
        def build_invocation(state)
          {
            executionSuccessful: !state[:had_errors]
          }
        end
      end
    end
  end
end

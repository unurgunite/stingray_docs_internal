# frozen_string_literal: true

require 'optparse'

require 'docscribe/cli/options'
require 'docscribe/cli/run'

module Docscribe
  module CLI
    # Two-pass update: rebuild docs then re-merge with RBS types.
    #
    # Usage:
    #   docscribe update_types [directory|file]
    #
    # Pass 1: `-AkB --rbs-collection <dir>` — aggressive rebuild, keep descriptions,
    #   no boilerplate, using RBS collection signatures.
    # Pass 2: `-aB --rbs-collection <dir>` — safe merge cleanup, no boilerplate,
    #   using RBS collection signatures.
    module UpdateTypes
      BANNER = <<~TEXT
        Usage: docscribe update_types [directory|file] [options]

        Two-pass type-aware documentation update.

        Pass 1 (aggressive):  docscribe -AkB --rbs-collection <dir>
          rebuild doc blocks, keep descriptions, no boilerplate

        Pass 2 (safe):        docscribe -aB --rbs-collection <dir>
          safe merge cleanup, no boilerplate

        See `docscribe --help` for type options (--rbs, --sig-dir, --rbs-collection, --[no-]validate-types).

      TEXT

      class << self
        # @param [Array<String>] argv
        # @return [Integer]
        def run(argv)
          options = parse_options(argv)
          target = options[:dir]
          @extra_argv = options[:extra_argv]

          announce_start

          exit1 = run_first_pass(target)
          return exit1 unless exit1.zero?

          exit2 = run_second_pass(target)
          return exit2 unless exit2.zero?

          announce_complete
          0
        end

        private

        # @private
        # @param [Array<String>] argv
        # @return [Hash<Symbol, Object>]
        def parse_options(argv) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
          options = { dir: '.', extra_argv: [] }
          extra_argv = []
          OptionParser.new(BANNER) do |opts|
            opts.on('-h', '--help', 'Show this help') { puts opts or exit 0 }
            opts.on('--[no-]rbs', 'Use RBS signatures when available') do |v|
              extra_argv << (v ? '--rbs' : '--no-rbs')
            end
            opts.on('--sig-dir DIR', 'Add an RBS signature directory (repeatable). Implies --rbs.') do |v|
              extra_argv << '--sig-dir' << v
            end
            opts.on('--rbs-collection', 'Auto-discover RBS collection from rbs_collection.lock.yaml. Implies --rbs.') do
              extra_argv << '--rbs-collection'
            end
            opts.on('--[no-]validate-types', 'Validate YARD types against inferred/RBS types (optional, default: off)') do |v|
              extra_argv << (v ? '--validate-types' : '--no-validate-types')
            end
            opts.parse!(argv)
          end
          options[:dir] = argv.first if argv.any?
          options[:extra_argv] = extra_argv
          @extra_argv = extra_argv
          options
        end

        # @private
        # @return [void]
        def announce_start
          puts 'Docscribe: Running type-aware documentation update...'
          puts
        end

        # @private
        # @param [String] target
        # @return [Integer]
        def run_first_pass(target) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          dir_for_flag = File.file?(target) ? File.dirname(target) : target
          has_collection = File.exist?(File.join(dir_for_flag, 'rbs_collection.lock.yaml')) || File.exist?('rbs_collection.lock.yaml')
          flag = has_collection ? '--rbs-collection' : '--rbs'
          extra = @extra_argv || []
          filtered = extra.reject { |a| %w[--no-rbs --no-validate-types].include?(a) }
          has_rbs_flag = extra.any? { |a| %w[--rbs --rbs-collection --no-rbs].include?(a) }
          has_no_rbs = extra.include?('--no-rbs')
          argv1 = ['-AkB']
          argv1.concat(filtered)
          if has_rbs_flag
            argv1 << dir_for_flag unless has_no_rbs || argv1.include?(dir_for_flag)
          else
            argv1 << flag << dir_for_flag
          end
          puts "Pass 1: Aggressive rebuild with #{has_collection ? 'RBS collection' : 'RBS'}#{' + validate-types' if extra.include?('--validate-types')}..."
          options1 = Docscribe::CLI::Options.parse!(argv1)
          Docscribe::CLI::Run.run(options: options1, argv: [target])
        end

        # @private
        # @param [String] target
        # @return [Integer]
        def run_second_pass(target) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          dir_for_flag = File.file?(target) ? File.dirname(target) : target
          has_collection = File.exist?(File.join(dir_for_flag, 'rbs_collection.lock.yaml')) || File.exist?('rbs_collection.lock.yaml')
          flag = has_collection ? '--rbs-collection' : '--rbs'
          extra = @extra_argv || []
          filtered = extra.reject { |a| %w[--no-rbs --no-validate-types].include?(a) }
          has_rbs_flag = extra.any? { |a| %w[--rbs --rbs-collection --no-rbs].include?(a) }
          has_no_rbs = extra.include?('--no-rbs')
          argv2 = ['-aB']
          argv2.concat(filtered)
          if has_rbs_flag
            argv2 << dir_for_flag unless has_no_rbs || argv2.include?(dir_for_flag)
          else
            argv2 << flag << dir_for_flag
          end
          puts "Pass 2: Safe merge with #{has_collection ? 'RBS collection' : 'RBS'}#{' + validate-types' if extra.include?('--validate-types')}..."
          options2 = Docscribe::CLI::Options.parse!(argv2)
          Docscribe::CLI::Run.run(options: options2, argv: [target])
        end

        # @private
        # @return [void]
        def announce_complete
          puts
          puts 'Docscribe: Type-aware documentation update complete.'
        end
      end
    end
  end
end

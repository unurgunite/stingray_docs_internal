# frozen_string_literal: true

require 'docscribe/cli/options'
require 'docscribe/cli/run'

module Docscribe
  # CLI entry point and command dispatch.
  module CLI
    COMMANDS = {
      'check_for_comments' => :CheckForComments,
      'config' => :ConfigDump,
      'coverage' => :Coverage,
      'generate' => :Generate,
      'init' => :Init,
      'rbs' => :RbsGen,
      'server' => :ServerCmd,
      'sigs' => :Sigs,
      'update_types' => :UpdateTypes
    }.freeze

    # Subcommands whose file name differs from the command name.
    SUBCOMMAND_FILES = {
      'config' => 'config_dump',
      'rbs' => 'rbs_gen'
    }.freeze

    class << self
      # @param [Array<String>] argv
      # @return [Integer]
      def run(argv)
        argv = argv.dup
        return dispatch_subcommand(argv) if subcommand?(argv.first)

        options = Docscribe::CLI::Options.parse!(argv)
        Docscribe::CLI::Run.run(options: options, argv: argv)
      end

      private

      # @private
      # @param [String?] cmd
      # @return [Boolean]
      def subcommand?(cmd)
        COMMANDS.key?(cmd)
      end

      # @private
      # @param [Array<String>] argv
      # @return [Integer]
      def dispatch_subcommand(argv)
        cmd = argv.shift
        const_name = COMMANDS[cmd]
        return 0 unless const_name

        require "docscribe/cli/#{SUBCOMMAND_FILES.fetch(cmd) { cmd }}"
        Docscribe::CLI.const_get(const_name).run(argv)
      end
    end
  end
end

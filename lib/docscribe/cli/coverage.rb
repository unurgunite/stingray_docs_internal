# frozen_string_literal: true

require 'optparse'
require 'docscribe/config'
require 'docscribe/cli/config_builder'
require 'docscribe/cli/options'

module Docscribe
  module CLI
    # Generate documentation coverage report for Ruby files.
    module Coverage
      BANNER = <<~TEXT
        Usage: docscribe coverage [options] [paths]

        Generate documentation coverage report.

        Options:
      TEXT

      # @!attribute [rw] total_methods
      #   @return [Integer]
      #   @param [Integer] value
      #
      # @!attribute [rw] documented_methods
      #   @return [Integer]
      #   @param [Integer] value
      #
      # @!attribute [rw] total_params
      #   @return [Integer]
      #   @param [Integer] value
      #
      # @!attribute [rw] documented_params
      #   @return [Integer]
      #   @param [Integer] value
      #
      # @!attribute [rw] total_returns
      #   @return [Integer]
      #   @param [Integer] value
      #
      # @!attribute [rw] documented_returns
      #   @return [Integer]
      #   @param [Integer] value
      CoverageStats = Struct.new(
        :total_methods, :documented_methods,
        :total_params, :documented_params,
        :total_returns, :documented_returns,
        keyword_init: true
      )

      # Struct tracking documentation coverage metrics per file.
      class CoverageStats
        # @return [Integer, Float]
        def method_coverage
          total_methods.zero? ? 100.0 : (documented_methods.to_f / total_methods * 100).round(1)
        end

        # @return [Integer, Float]
        def param_coverage
          total_params.zero? ? 100.0 : (documented_params.to_f / total_params * 100).round(1)
        end

        # @return [Integer, Float]
        def return_coverage
          total_returns.zero? ? 100.0 : (documented_returns.to_f / total_returns * 100).round(1)
        end
      end

      class << self
        # @param [Array<String>] argv
        # @return [Integer]
        def run(argv)
          opts = parse_options(argv)
          return 0 if opts[:help]

          conf = Docscribe::Config.load(opts[:config])
          paths = expand_paths(argv, conf)

          stats = analyze_coverage(paths, conf)

          print_report(stats, opts)
          0
        end

        private

        # @private
        # @param [Array<String>] argv
        # @return [Hash<Symbol, Object>]
        def parse_options(argv)
          opts = { config: nil, format: 'text' }
          build_parser(opts).parse!(argv)
          opts
        end

        # @private
        # @param [Hash<Symbol, Object>] opts
        # @return [OptionParser]
        def build_parser(opts)
          OptionParser.new do |o|
            o.banner = BANNER
            o.on('--config PATH', 'Path to config file') { |v| opts[:config] = v }
            o.on('--format FORMAT', 'Output format (text, json)') { |v| opts[:format] = v }
            o.on('-h', '--help', 'Show help') do
              opts[:help] = true
              puts o
            end
          end
        end

        # @private
        # @param [Array<String>] argv
        # @param [Docscribe::Config] conf
        # @return [Array<String>]
        def expand_paths(argv, conf)
          require 'pathname'
          args = argv.empty? ? ['.'] : argv
          files = expand_files(args)
          files.uniq.sort.select { |p| conf.process_file?(p) }
        end

        # @private
        # @param [Array<String>] args
        # @return [Array<String>]
        def expand_files(args)
          files = [] #: Array[String]
          args.each do |path|
            if File.directory?(path)
              files.concat(Dir.glob(File.join(path, '**', '*.rb')))
            elsif File.file?(path)
              files << path
            end
          end
          files
        end

        # @private
        # @param [Array<String>] paths
        # @param [Docscribe::Config] _conf
        # @return [Docscribe::CLI::Coverage::CoverageStats]
        def analyze_coverage(paths, _conf)
          require 'docscribe/parsing'
          require 'parser/current'

          stats = init_stats
          paths.each { |path| analyze_file(path, stats) }
          stats
        end

        # @private
        # @return [Docscribe::CLI::Coverage::CoverageStats]
        def init_stats
          CoverageStats.new(
            total_methods: 0, documented_methods: 0,
            total_params: 0, documented_params: 0,
            total_returns: 0, documented_returns: 0
          )
        end

        # @private
        # @param [String] path
        # @param [Docscribe::CLI::Coverage::CoverageStats] stats
        # @raise [StandardError]
        # @return [void]
        # @return [nil] if StandardError
        def analyze_file(path, stats)
          src = File.read(path)
          buffer = Parser::Source::Buffer.new(path, source: src)
          ast = Docscribe::Parsing.parse_buffer(buffer)
          analyze_node(ast, stats, src) if ast
        rescue StandardError => e
          warn "Skipping #{path}: #{e.message}" if ENV.fetch('DOCSCRIBE_DEBUG', false)
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::Coverage::CoverageStats] stats
        # @param [String] src
        # @return [void]
        def analyze_node(node, stats, src)
          return unless node.is_a?(Parser::AST::Node)

          analyze_method_node(node, stats, src) if %i[def defs].include?(node.type)

          node.children.each { |child| analyze_node(child, stats, src) if child.is_a?(Parser::AST::Node) }
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::Coverage::CoverageStats] stats
        # @param [String] src
        # @return [void]
        def analyze_method_node(node, stats, src)
          stats.total_methods += 1
          doc_comment = extract_doc_comment(src, node.loc.expression.line)

          if doc_comment
            analyze_documented_method(node, stats, doc_comment)
          else
            stats.total_returns += 1
            count_method_params(node, stats)
          end
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::Coverage::CoverageStats] stats
        # @param [String] doc_comment
        # @return [void]
        def analyze_documented_method(node, stats, doc_comment)
          stats.documented_methods += 1
          stats.documented_returns += 1 if doc_comment.match?(/@return\b/)
          stats.total_returns += 1

          param_matches = doc_comment.scan(/@param\b/)
          param_count = count_params(node)
          stats.total_params += param_count
          stats.documented_params += [param_matches.size, param_count].min
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::Coverage::CoverageStats] stats
        # @return [void]
        def count_method_params(node, stats)
          stats.total_params += count_params(node)
        end

        # @private
        # @param [Parser::AST::Node] node
        # @return [Integer]
        def count_params(node)
          args_node = node.children[2] || node.children[1]
          return 0 unless args_node.is_a?(Parser::AST::Node) && args_node.type == :args

          args_node.children.count { |a| %i[arg optarg kwarg kwoptarg restarg].include?(a.type) }
        end

        # @private
        # @param [String] src
        # @param [Integer] method_line
        # @return [String?]
        def extract_doc_comment(src, method_line)
          lines = src.lines
          comment_lines = collect_comment_lines(lines, method_line)
          comment_lines.empty? ? nil : comment_lines.join
        end

        # @private
        # @param [Array<String>] lines
        # @param [Integer] method_line
        # @return [Array<String>]
        def collect_comment_lines(lines, method_line)
          comment_lines = [] #: Array[String]
          idx = method_line - 2
          while idx >= 0
            line = lines[idx]
            break unless line =~ /^\s*#/

            comment_lines.unshift(line)
            idx -= 1
          end
          comment_lines
        end

        # @private
        # @param [Docscribe::CLI::Coverage::CoverageStats] stats
        # @param [Hash<Symbol, Object>] opts
        # @return [void]
        def print_report(stats, opts)
          case opts[:format]
          when 'json'
            print_json_report(stats)
          else
            print_text_report(stats)
          end
        end

        # @private
        # @param [Docscribe::CLI::Coverage::CoverageStats] stats
        # @return [void]
        def print_json_report(stats)
          require 'json'
          puts JSON.pretty_generate(
            methods: report_entry(stats.total_methods, stats.documented_methods, stats.method_coverage),
            params: report_entry(stats.total_params, stats.documented_params, stats.param_coverage),
            returns: report_entry(stats.total_returns, stats.documented_returns, stats.return_coverage)
          )
        end

        # @private
        # @param [Integer] total
        # @param [Integer] documented
        # @param [Integer, Float] coverage
        # @return [Hash<Symbol, Integer, Float>]
        def report_entry(total, documented, coverage)
          { total: total, documented: documented, coverage: coverage }
        end

        # @private
        # @param [Docscribe::CLI::Coverage::CoverageStats] stats
        # @return [void]
        def print_text_report(stats)
          puts 'Documentation Coverage Report'
          puts '============================='
          puts
          puts "Methods: #{stats.documented_methods}/#{stats.total_methods} (#{stats.method_coverage}%)"
          puts "Params:  #{stats.documented_params}/#{stats.total_params} (#{stats.param_coverage}%)"
          puts "Returns: #{stats.documented_returns}/#{stats.total_returns} (#{stats.return_coverage}%)"
        end
      end
    end
  end
end

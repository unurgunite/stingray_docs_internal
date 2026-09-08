# frozen_string_literal: true

require 'English'
require 'optparse'
require 'fileutils'
require 'docscribe/parsing'
require 'docscribe/types/yard/parser'
require 'docscribe/types/yard/formatter'

module Docscribe
  module CLI
    # CLI subcommand to generate RBS files from YARD documentation
    module RbsGen
      BANNER = <<~TEXT
        Usage: docscribe rbs [options] [files...]

        Generate RBS signature files from YARD documentation.

      TEXT

      # @!attribute [rw] params
      #   @return [Array<Docscribe::CLI::RbsGen::ParamTag>]
      #   @param [Array<Docscribe::CLI::RbsGen::ParamTag>] value
      #
      # @!attribute [rw] return_type
      #   @return [String?]
      #   @param [String?] value
      #
      # @!attribute [rw] options
      #   @return [Array<Docscribe::CLI::RbsGen::ParamTag>]
      #   @param [Array<Docscribe::CLI::RbsGen::ParamTag>] value
      YardTags = Struct.new(:params, :return_type, :options, keyword_init: true) #: Class[YardTags]
      # @!attribute [rw] name
      #   @return [String]
      #   @param [String] value
      #
      # @!attribute [rw] type
      #   @return [String]
      #   @param [String] value
      ParamTag = Struct.new(:name, :type, keyword_init: true) #: Class[ParamTag]
      # @!attribute [rw] name
      #   @return [Symbol]
      #   @param [Symbol] value
      #
      # @!attribute [rw] scope
      #   @return [Symbol]
      #   @param [Symbol] value
      #
      # @!attribute [rw] container
      #   @return [String?]
      #   @param [String?] value
      #
      # @!attribute [rw] file
      #   @return [String]
      #   @param [String] value
      #
      # @!attribute [rw] line
      #   @return [Integer]
      #   @param [Integer] value
      #
      # @!attribute [rw] yard_tags
      #   @return [Docscribe::CLI::RbsGen::YardTags?]
      #   @param [Docscribe::CLI::RbsGen::YardTags?] value
      MethodDef = Struct.new(:name, :scope, :container, :file, :line, :yard_tags, keyword_init: true) #: Class[MethodDef]
      # @!attribute [rw] containers
      #   @return [Array<String>]
      #   @param [Array<String>] value
      #
      # @!attribute [rw] method_defs
      #   @return [Array<Docscribe::CLI::RbsGen::MethodDef>]
      #   @param [Array<Docscribe::CLI::RbsGen::MethodDef>] value
      #
      # @!attribute [rw] path
      #   @return [String]
      #   @param [String] value
      #
      # @!attribute [rw] comment_map
      #   @return [Hash<Integer, String>]
      #   @param [Hash<Integer, String>] value
      #
      # @!attribute [rw] src_lines
      #   @return [Array<String>]
      #   @param [Array<String>] value
      #
      # @!attribute [rw] inside_sclass
      #   @return [Boolean]
      #   @param [Boolean] value
      WalkContext = Struct.new(:containers, :method_defs, :path, :comment_map, :src_lines, :inside_sclass,
                               keyword_init: true) #: Class[WalkContext]

      class << self
        # @param [Array<String>] argv
        # @return [Integer]
        def run(argv)
          options = parse_options(argv)
          paths = expand_paths(argv)
          return no_files_found if paths.empty?

          run_with(options, paths)
        end

        private

        # @private
        # @param [Array<String>] argv
        # @return [Hash<Symbol, Object>]
        def parse_options(argv)
          options = { output_dir: 'sig', dry_run: false, force: false }
          OptionParser.new(BANNER) do |opts|
            opts.on('-o', '--output DIR', 'Output directory (default: sig)') { |d| options[:output_dir] = d }
            opts.on('-n', '--dry-run', 'Print generated RBS to stdout') { options[:dry_run] = true }
            opts.on('-f', '--force', 'Overwrite existing files') { options[:force] = true }
            opts.on('-h', '--help', 'Show this help') { puts opts or exit 0 }
          end.parse!(argv)
          options
        end

        # @private
        # @param [Array<String>] args
        # @return [Array<String>]
        def expand_paths(args)
          files = [] #: Array[String]
          args = ['.'] if args.empty?
          args.each { |path| expand_single_path(files, path) }
          files.uniq.sort
        end

        # @private
        # @param [Array<String>] files
        # @param [String] path
        # @return [void]
        def expand_single_path(files, path)
          if File.directory?(path)
            files.concat(Dir.glob(File.join(path, '**', '*.rb')))
          elsif File.file?(path)
            files << path
          else
            warn "Skipping missing path: #{path}"
          end
        end

        # @private
        # @return [Integer]
        def no_files_found
          warn 'No files found. Pass files or directories (e.g. `docscribe rbs lib`).'
          2
        end

        # @private
        # @param [Hash<Symbol, Object>] options
        # @param [Array<String>] paths
        # @return [Integer]
        def run_with(options, paths)
          errors = 0
          paths.each do |path|
            generate_for_file(path, options) or (errors += 1)
          end
          errors.zero? ? 0 : 1
        end

        # @private
        # @param [String] path
        # @param [Hash<Symbol, Object>] options
        # @raise [Parser::SyntaxError]
        # @raise [StandardError]
        # @return [Boolean]
        # @return [Boolean] if Parser::SyntaxError
        # @return [Boolean] if StandardError
        def generate_for_file(path, options)
          process_source?(File.read(path), path, options)
        rescue Parser::SyntaxError => e
          warn "Syntax error in #{path}: #{e.message}"
          false
        rescue StandardError => e
          warn "Error processing #{path}: #{e.class}: #{e.message}"
          false
        end

        # @private
        # @param [String] src
        # @param [String] path
        # @param [Hash<Symbol, Object>] options
        # @return [Boolean]
        def process_source?(src, path, options)
          src_lines = src.lines
          res = Docscribe::Parsing.parse_with_comments(src, file: path)
          return false unless res

          ast = res[0]
          method_defs = ast ? walk_source(ast, res[1], path, src_lines) : [] #: Array[MethodDef]
          return true if method_defs.empty?

          content = build_rbs_content(method_defs)
          return false unless content

          output_rbs(content, path, options)
          true
        end

        # @private
        # @param [Parser::AST::Node] ast
        # @param [Array<Parser::Source::Comment>?] comments
        # @param [String] path
        # @param [Array<String>] src_lines
        # @return [Array<Docscribe::CLI::RbsGen::MethodDef>]
        def walk_source(ast, comments, path, src_lines)
          comment_map = build_comment_map(comments)
          containers = [] #: Array[String]
          mdefs = [] #: Array[MethodDef]
          ctx = WalkContext.new(containers: containers, method_defs: mdefs, path: path, comment_map: comment_map,
                                src_lines: src_lines, inside_sclass: false)
          walk_for_methods(ast, ctx)
          ctx.method_defs
        end

        # @private
        # @param [String] content
        # @param [String] path
        # @param [Hash<Symbol, Object>] options
        # @return [void]
        def output_rbs(content, path, options)
          if options[:dry_run]
            puts content
          else
            write_file(content, path, options)
          end
        end

        # @private
        # @param [Array<Parser::Source::Comment>?] comments
        # @return [Hash<Integer, String>]
        def build_comment_map(comments)
          map = {} #: Hash[Integer, String]
          return map unless comments

          comments.each do |comment|
            map[comment.location.line] = comment.text
          end
          map
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::RbsGen::WalkContext] ctx
        # @return [void]
        def walk_for_methods(node, ctx)
          return unless node.is_a?(Parser::AST::Node)

          case node.type
          when :class, :module then walk_class_module(node, ctx)
          when :sclass then walk_sclass(node, ctx)
          when :def then collect_def(node, ctx)
          when :defs then collect_defs(node, ctx)
          else walk_children(node, ctx)
          end
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::RbsGen::WalkContext] ctx
        # @return [void]
        def walk_class_module(node, ctx)
          ctx.containers.push(const_name(node.children[0]))
          node.children.drop(1).each { |c| walk_for_methods(c, ctx) }
          ctx.containers.pop
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::RbsGen::WalkContext] ctx
        # @return [void]
        def walk_sclass(node, ctx)
          sc_ctx = WalkContext.new(
            containers: ctx.containers,
            method_defs: ctx.method_defs,
            path: ctx.path,
            comment_map: ctx.comment_map,
            src_lines: ctx.src_lines,
            inside_sclass: true
          )
          node.children.drop(1).each { |c| walk_for_methods(c, sc_ctx) }
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::RbsGen::WalkContext] ctx
        # @return [void]
        def walk_children(node, ctx)
          node.children.each { |c| walk_for_methods(c, ctx) }
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::RbsGen::WalkContext] ctx
        # @return [void]
        def collect_def(node, ctx)
          line = node.loc&.line || 1
          yard_tags = parse_yard_tags_for_line(line, ctx)

          ctx.method_defs << MethodDef.new(
            name: node.children[0],
            scope: ctx.inside_sclass ? :class : :instance,
            container: container_name(ctx.containers),
            file: ctx.path,
            line: line,
            yard_tags: yard_tags
          )
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Docscribe::CLI::RbsGen::WalkContext] ctx
        # @return [void]
        def collect_defs(node, ctx)
          line = node.loc&.line || 1
          yard_tags = parse_yard_tags_for_line(line, ctx)

          ctx.method_defs << MethodDef.new(
            name: node.children[1],
            scope: :class,
            container: container_name(ctx.containers),
            file: ctx.path,
            line: line,
            yard_tags: yard_tags
          )
        end

        # @private
        # @param [Integer] line
        # @param [Docscribe::CLI::RbsGen::WalkContext] ctx
        # @return [Docscribe::CLI::RbsGen::YardTags?]
        def parse_yard_tags_for_line(line, ctx)
          yard_block = find_yard_block(line, ctx.comment_map, ctx.src_lines)
          yard_block.any? ? parse_yard_tags(yard_block) : nil
        end

        # @private
        # @param [Integer] line
        # @param [Hash<Integer, String>] comment_map
        # @param [Array<String>] src_lines
        # @return [Array<String>]
        def find_yard_block(line, comment_map, src_lines)
          block = [] #: Array[String]
          idx = line - 2
          while idx >= 0
            break if src_lines[idx].to_s.strip.empty?

            block.unshift(comment_map[idx + 1]) if comment_map.key?(idx + 1)
            break unless comment_map.key?(idx + 1) || block.empty?

            idx -= 1
          end
          block
        end

        # @private
        # @param [Array<String>] comment_lines
        # @return [Docscribe::CLI::RbsGen::YardTags]
        def parse_yard_tags(comment_lines)
          params = [] #: Array[ParamTag]
          opts = [] #: Array[ParamTag]
          state = { params: params, options: opts, return_type: nil }
          comment_lines.each { |line| parse_yard_line(line, state) }
          return_type = state[:return_type] #: String?
          YardTags.new(params: params, return_type: return_type, options: opts)
        end

        # @private
        # @param [String] line
        # @param [Hash<Symbol, Object>] state
        # @return [void]
        def parse_yard_line(line, state)
          text = line.sub(/\A#\s*/, '')
          parse_param_tag(text, state) || parse_option_tag(text, state) || parse_return_tag(text, state)
        end

        # @private
        # @param [String] text
        # @param [Hash<Symbol, Object>] state
        # @return [void]
        def parse_param_tag(text, state)
          if (m = text.match(/\A@param\s+\[([^\]]+)\]\s+(\S+)\s*/))
            state[:params] << ParamTag.new(name: m[2].to_s, type: m[1].to_s)
          elsif (m = text.match(/\A@param\s+(\S+)\s+\[([^\]]+)\]\s*/))
            state[:params] << ParamTag.new(name: m[1].to_s, type: m[2].to_s)
          end
        end

        # @private
        # @param [String] text
        # @param [Hash<Symbol, Object>] state
        # @return [void]
        def parse_option_tag(text, state)
          return unless (m = text.match(/\A@option\s+\S+\s+\[([^\]]+)\]\s+:?(\S+)\s*/))

          state[:options] << ParamTag.new(name: m[2].to_s, type: m[1].to_s)
        end

        # @private
        # @param [String] text
        # @param [Hash<Symbol, Object>] state
        # @return [void]
        def parse_return_tag(text, state)
          return unless (m = text.match(/\A@return\s+\[([^\]]+)\]\s*/))

          state[:return_type] = m[1]
        end

        # @private
        # @param [Array<String>] containers
        # @return [String?]
        def container_name(containers)
          containers.empty? ? nil : containers.join('::')
        end

        # @private
        # @param [Parser::AST::Node] node
        # @return [String]
        def const_name(node)
          return node.to_s unless node.is_a?(Parser::AST::Node)
          return node.children[1].to_s if node.type == :const

          node.children.map { |c| c.is_a?(Parser::AST::Node) ? const_name(c) : c.to_s }.join('::')
        end

        # @private
        # @param [Array<Docscribe::CLI::RbsGen::MethodDef>] method_defs
        # @return [String]
        def build_rbs_content(method_defs)
          grouped = method_defs.group_by { |m| m.container || '' }

          lines = [] #: Array[String]
          grouped.each { |container, methods| append_group(lines, container, methods) }

          "#{lines.join("\n")}\n"
        end

        # @private
        # @param [Array<String>] lines
        # @param [String] container
        # @param [Array<Docscribe::CLI::RbsGen::MethodDef>] methods
        # @return [void]
        def append_group(lines, container, methods)
          lines << '' unless lines.empty?
          if container.empty?
            methods.each { |m| lines << format_method_sig(m) }
          else
            lines << "class #{container}"
            methods.each { |m| lines << "  #{format_method_sig(m)}" }
            lines << 'end'
          end
        end

        # @private
        # @param [Docscribe::CLI::RbsGen::MethodDef] method
        # @return [String]
        def format_method_sig(method)
          prefix = method.scope == :class ? 'self.' : ''
          ret = return_type_rbs(method)
          param_strs = build_param_strs(method)

          if param_strs.any?
            "def #{prefix}#{method.name}: (#{param_strs.join(', ')}) -> #{ret}"
          else
            "def #{prefix}#{method.name}: () -> #{ret}"
          end
        end

        # @private
        # @param [Docscribe::CLI::RbsGen::MethodDef] method
        # @return [Array<String>]
        def build_param_strs(method)
          tags = method.yard_tags
          strs = (tags&.params || []).map { |p| "#{type_to_rbs(p.type)} #{p.name}" }
          (tags&.options || []).each { |o| strs << "?#{type_to_rbs(o.type)} #{o.name}" }
          strs
        end

        # @private
        # @param [Docscribe::CLI::RbsGen::MethodDef] method
        # @return [String]
        def return_type_rbs(method)
          tags = method.yard_tags
          rt = tags&.return_type
          return 'untyped' unless rt

          type_to_rbs(rt)
        end

        # @private
        # @param [String] yard_type
        # @return [String]
        def type_to_rbs(yard_type)
          ast = Docscribe::Types::Yard.parse(yard_type)
          Docscribe::Types::Yard::Formatter.to_rbs(ast)
        end

        # @private
        # @param [String] content
        # @param [String] source_path
        # @param [Hash<Symbol, Object>] options
        # @return [void]
        def write_file(content, source_path, options)
          out_path = rbs_output_path(source_path, options)
          dir = File.dirname(out_path)

          if File.exist?(out_path) && !options[:force]
            warn "Skipping #{out_path} (use --force to overwrite)"
            return
          end

          FileUtils.mkdir_p(dir)
          File.write(out_path, content)
          puts "Generated #{out_path}"
        end

        # @private
        # @param [String] source_path
        # @param [Hash<Symbol, Object>] options
        # @return [String]
        def rbs_output_path(source_path, options)
          abs = File.expand_path(source_path)
          pwd = File.expand_path(Dir.pwd)
          rel = abs.start_with?(pwd) ? abs.sub("#{pwd}/", '') : File.basename(abs)
          rel.sub(/\.rb\z/, '.rbs').then { |r| File.join(options[:output_dir], r) }
        end
      end
    end
  end
end

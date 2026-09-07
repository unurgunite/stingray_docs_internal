# frozen_string_literal: true

require 'docscribe/plugin'
require 'docscribe/infer'
require 'docscribe/inline_rewriter/source_helpers'
require 'docscribe/types/yard/validator'
require 'docscribe/validator/type_mismatch_validator'
require 'docscribe/validator/generic_compatibility'

module Docscribe
  module InlineRewriter
    # Build generated YARD-style doc lines for methods and attribute helpers.
    #
    # DocBuilder combines:
    # - Ruby visibility/container metadata from Collector
    # - optional external signatures from Sorbet/RBS providers
    # - fallback AST inference from Docscribe::Infer
    #
    # It is responsible for producing complete doc blocks for aggressive mode
    # and "missing lines only" payloads for safe merge mode.
    module DocBuilder
      module_function

      PARAM_TYPE_COLLECTORS = {
        arg: lambda { |arg_node, param_types, external_sig, config|
          collect_param_type(
            arg_node,
            param_types,
            external_sig,
            config,
            infer_name: nil
          )
        },

        optarg: lambda { |arg_node, param_types, external_sig, config|
          collect_optarg_param_type(
            arg_node,
            param_types,
            external_sig,
            config,
            infer_name: nil
          )
        },

        kwarg: lambda { |arg_node, param_types, external_sig, config|
          collect_param_type(
            arg_node,
            param_types,
            external_sig,
            config,
            infer_name: ->(param_name) { "#{param_name}:" }
          )
        },

        kwoptarg: lambda { |arg_node, param_types, external_sig, config|
          collect_optarg_param_type(
            arg_node,
            param_types,
            external_sig,
            config,
            infer_name: ->(param_name) { "#{param_name}:" }
          )
        }
      }.freeze

      # Build
      #
      # @note module_function: defines #build (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] opts additional keyword options forwarded to doc_setup
      # @raise [StandardError]
      # @return [String, nil]
      # @return [nil] if StandardError
      def build(insertion, config:, **opts)
        setup = doc_setup(insertion, config: config, **opts)
        return nil unless setup

        build_unsafe(insertion, config: config, setup: setup, **opts)
      rescue StandardError => e
        debug_warn(e, insertion: insertion, name: '(unknown)', phase: 'DocBuilder.build')
        nil
      end

      # Build merge additions
      #
      # @note module_function: defines #build_merge_additions (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [Array<String>] existing_lines existing doc comment lines being merged
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] options additional keyword options forwarded to downstream methods
      # @raise [StandardError]
      # @return [String, nil]
      # @return [nil] if StandardError
      def build_merge_additions(insertion, existing_lines:, config:, **options)
        setup = doc_setup(insertion, config: config, **options)
        return '' unless setup

        info = parse_existing_doc_tags(existing_lines)
        merge_dest_lines(existing_lines, setup: setup, insertion: insertion, config: config, info: info,
                                         param_types: options[:param_types])
      rescue StandardError => e
        debug_warn(e, insertion: insertion, name: setup&.dig(:name) || '(unknown)',
                      phase: 'DocBuilder.build_merge_additions')
        nil
      end

      # Build missing merge result
      #
      # @note module_function: defines #build_missing_merge_result (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [Array<String>] existing_lines existing doc comment lines being merged
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] options additional keyword options forwarded to downstream methods
      # @raise [StandardError]
      # @return [Docscribe::InlineRewriter::DocBuilder::missingMergeResult]
      # @return [Hash] if StandardError
      def build_missing_merge_result(insertion, existing_lines:, config:, **options)
        setup = doc_setup(insertion, config: config, **options)
        return { lines: [], reasons: [] } unless setup

        info = parse_existing_doc_tags(existing_lines)
        collect_all_missing(setup, info, insertion, config, options)
      rescue StandardError => e
        debug_warn(e, insertion: insertion, name: setup&.dig(:name) || '(unknown)',
                      phase: 'DocBuilder.build_missing_merge_result')
        { lines: [], reasons: [] }
      end

      # Doc setup
      #
      # @note module_function: defines #doc_setup (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] opts additional options
      # @return [Docscribe::InlineRewriter::DocBuilder::setup, nil]
      def doc_setup(insertion, config:, **opts)
        node = insertion.node
        name = SourceHelpers.node_name(node)
        return nil unless name

        setup = extract_base_setup(insertion, name)
        resolve_doc_setup!(setup, node, name, config, opts)
      end

      # Build unsafe
      #
      # @note module_function: defines #build_unsafe (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with name, normal_type, scope, visibility
      # @param [Hash<Symbol, Object>] opts additional options including infer_default, fallback_type, treat_options_keyword_as_hash
      # @return [String]
      def build_unsafe(insertion, config:, setup:, **opts)
        _, pl, rt = build_param_and_raise_info(setup, config, opts)
        lines = build_doc_lines(setup, config: config, insertion: insertion, params_lines: pl, raise_types: rt,
                                       override_tags: opts[:override_tags],
                                       return_description: opts[:return_description],
                                       description: opts[:description])
        lines.map { |l| "#{l}\n" }.join
      end

      # Build param and raise info
      #
      # @note module_function: defines #build_param_and_raise_info (visibility: private)
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with name, normal_type, scope, visibility
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] opts additional options including
      # @return [(Hash<String, String>, nil, Array<String>, nil, Array<String>)]
      def build_param_and_raise_info(setup, config, opts)
        pt = opts[:param_types] || build_param_types_from_node(setup[:node], external_sig: setup[:external_sig],
                                                                             config: config)
        pl = if config.emit_param_tags?
               build_params_lines(setup[:node], setup[:indent], external_sig: setup[:external_sig], config: config,
                                                                param_types_override: pt,
                                                                param_descriptions: opts[:param_descriptions])
             end
        rt = config.emit_raise_tags? ? Docscribe::Infer.infer_raises_from_node(setup[:node]) : [] #: Array[String]
        [pt, pl, rt]
      end

      # Resolve doc setup
      #
      # @note module_function: defines #resolve_doc_setup! (visibility: private)
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with name, normal_type, scope, visibility
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @param [Symbol] name the method name string
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] opts additional options including
      # @return [Docscribe::InlineRewriter::DocBuilder::setup]
      def resolve_doc_setup!(setup, node, name, config, opts)
        external_sig = resolve_external_sig(setup[:container], setup[:scope], name, opts[:signature_provider], node)
        returns_spec = compute_returns_spec(node, config, opts[:param_types], opts[:core_rbs_provider],
                                            signature_provider: opts[:signature_provider],
                                            container: setup[:container])
        normal_type = opts[:return_type_override] || external_sig&.return_type || returns_spec[:normal]

        setup.merge(
          external_sig: external_sig,
          normal_type: normal_type,
          rescue_specs: returns_spec[:rescues] || []
        )
      end

      # Extract base setup
      #
      # @note module_function: defines #extract_base_setup (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [Symbol] name the method name string
      # @return [Docscribe::InlineRewriter::DocBuilder::setup]
      def extract_base_setup(insertion, name)
        n = insertion.node
        { node: n, name: name, indent: SourceHelpers.line_indent(n), scope: insertion.scope,
          visibility: insertion.visibility, container: insertion.container,
          method_symbol: insertion.scope == :instance ? '#' : '.' }
      end

      # Resolve external sig
      #
      # @note module_function: defines #resolve_external_sig (visibility: private)
      # @param [String] container method container name
      # @param [Symbol] scope method scope symbol
      # @param [Symbol] name the method name string
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider external sig provider
      # @param [Parser::AST::Node] node
      # @return [Docscribe::Types::MethodSignature, nil]
      def resolve_external_sig(container, scope, name, signature_provider, node = nil)
        param_count, param_names = extract_sig_param_info(node)
        signature_provider&.signature_for(container: container, scope: scope, name: name,
                                          param_count: param_count, param_names: param_names)
      end

      # @note module_function: defines #extract_sig_param_info (visibility: private)
      # @param [Parser::AST::Node?] node
      # @return [(Integer?, Array<String>)]
      def extract_sig_param_info(node)
        empty = [] #: Array[String]
        return [nil, empty] unless node

        args = extract_args_from_node(node)
        empty = [] #: Array[String]
        return [nil, empty] unless args

        [args.children.length, args.children.map { |a| a.children.first.to_s if a.respond_to?(:children) }.compact]
      end

      # Compute returns spec
      #
      # @note module_function: defines #compute_returns_spec (visibility: private)
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<String, String>, nil] param_types hash accumulating parameter name-to-type mappings
      # @param [Docscribe::Types::RBS::Provider, nil] core_rbs_provider RBS type provider
      # @param [Docscribe::Types::ProviderChain?] signature_provider
      # @param [String?] container
      # @return [Docscribe::InlineRewriter::DocBuilder::returnsSpec]
      def compute_returns_spec(node, config, param_types, core_rbs_provider, # rubocop:disable Metrics/ParameterLists
                               signature_provider: nil, container: nil)
        Docscribe::Infer.returns_spec_from_node(
          node, fallback_type: config.fallback_type, nil_as_optional: config.nil_as_optional?,
                param_types: param_types, core_rbs_provider: core_rbs_provider,
                signature_provider: signature_provider, container: container
        )
      end

      # Parse existing doc tags
      #
      # @note module_function: defines #parse_existing_doc_tags (visibility: private)
      # @param [Array<String>] lines existing doc comment lines
      # @return [Docscribe::InlineRewriter::DocBuilder::parseInfo] parsed tag info
      def parse_existing_doc_tags(lines)
        init = init_parse_info
        tags_started = false
        joined_lines = join_multiline_tags(Array(lines))
        joined_lines.each_with_object(init) do |line, info|
          extract_all_comment_tags(line, info)
          tags_started = parse_existing_tag_line(line, info, tags_started)
        end
      end

      # Join @param/@return/@raise tag lines where the type bracket spans multiple lines.
      #
      # @note module_function: defines #join_multiline_tags (visibility: private)
      # @param [Array<String>] lines doc comment lines
      # @return [Array<String>]
      def join_multiline_tags(lines)
        result = [] #: Array[String]
        i = 0
        i = consume_tag_or_copy(lines, i, result) while i < lines.length
        result
      end

      # Consume tag line or copy verbatim
      #
      # @note module_function: defines #consume_tag_or_copy (visibility: private)
      # @param [Array<String>] lines doc comment lines
      # @param [Integer] idx current line index
      # @param [Array<String>] result result accumulator array
      # @return [Integer]
      def consume_tag_or_copy(lines, idx, result)
        if (c = lines[idx].sub(/^\s*#\s*/, '')) =~ /^@(param|return|raise)\s+\[/ && unbalanced_bracket?(c)
          buffer, consumed = join_tag_continuations(lines, idx)
          result << "# #{buffer}"
          idx + consumed
        else
          result << lines[idx]
          idx + 1
        end
      end

      # Join continuation lines for a multi-line tag type bracket.
      #
      # @note module_function: defines #join_tag_continuations (visibility: private)
      # @param [Array<String>] lines all doc comment lines
      # @param [Integer] start index of the @param/@return/@raise line
      # @return [(String, Integer)] joined content and number of lines consumed
      def join_tag_continuations(lines, start)
        buffer = +lines[start].sub(/^\s*#\s*/, '').dup
        i = start + 1
        while i < lines.length
          continuation = lines[i].sub(/^\s*#[ \t]/, '')
          break unless continuation.start_with?(' ')

          buffer << continuation.rstrip
          i += 1
          break unless unbalanced_bracket?(buffer)
        end
        [buffer, i - start]
      end

      # Check if bracket depth is positive (an opening `[` is unclosed).
      #
      # @note module_function: defines #unbalanced_bracket? (visibility: private)
      # @param [String] str string to check
      # @return [Boolean]
      def unbalanced_bracket?(str)
        depth = 0
        str.each_char do |c|
          depth += 1 if c == '['
          depth -= 1 if c == ']'
        end
        depth.positive?
      end

      # Parse a single doc comment line for tag info.
      #
      # @note module_function: defines #parse_existing_tag_line (visibility: private)
      # @param [String] line the doc comment line
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info mutable parse info accumulator
      # @param [Boolean] tags_started whether @tags have been seen
      # @return [Boolean] updated tags_started
      def parse_existing_tag_line(line, info, tags_started)
        content = line.sub(/^\s*# ?/, '').rstrip
        if content.start_with?('@')
          tags_started = true.tap { track_last_tag(content, info) }
          start_note_tag(line, info) if content.start_with?('@note ')
        elsif tags_started && info[:last_tag]
          append_note_continuation(line, info).tap { append_tag_continuation(content, info) }
        else
          info[:description] << content
        end
        tags_started
      end

      # Start a note tag
      #
      # @note module_function: defines #start_note_tag (visibility: private)
      # @param [String] line doc comment line
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash
      # @return [void]
      def start_note_tag(line, info)
        return if line.match?(/^\s*#\s*@note\s+module_function:/)

        empty = [] #: Array[String]
        info[:note_lines] << empty
        info[:note_lines].last << line.chomp
      end

      # Append note continuation lines
      #
      # @note module_function: defines #append_note_continuation (visibility: private)
      # @param [String] line doc comment line
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash
      # @return [Object]
      def append_note_continuation(line, info)
        return unless info[:last_tag] == :note && info[:note_lines].any?

        info[:note_lines].last << line.chomp
      end

      # Init parse info
      #
      # @note module_function: defines #init_parse_info (visibility: private)
      # @return [Docscribe::InlineRewriter::DocBuilder::parseInfo]
      def init_parse_info
        {
          param_names: {}, param_types: {}, param_descriptions: {},
          raise_types: {}, plugin_tags: {},
          has_return: false, return_type: nil, return_description: nil,
          has_private: false, has_protected: false, has_module_function_note: false,
          description: [],
          last_tag: nil, last_param: nil,
          note_lines: []
        }
      end

      # Merge dest lines
      #
      # @note module_function: defines #merge_dest_lines (visibility: private)
      # @param [Array<String>] existing_lines existing doc comment lines to merge into
      # @param [Hash<Symbol, Object>] ctx merge context hash (setup, insertion, config, info, param_types)
      # @return [String, nil]
      def merge_dest_lines(existing_lines, **ctx)
        merge_lines_with_context(existing_lines, **ctx)
      end

      # Merge lines with context
      #
      # @note module_function: defines #merge_lines_with_context (visibility: private)
      # @param [Array<String>] existing_lines existing doc comment lines being merged
      # @param [Hash<Symbol, Object>] ctx merge context (setup, insertion, config, info, param_types)
      # @return [String]
      def merge_lines_with_context(existing_lines, **ctx)
        s = ctx[:setup]
        i = s[:indent]
        config = ctx[:config]
        info = ctx[:info]
        base_ary = build_initial_line_ary(existing_lines, i)
        line_ary = merge_all_tag_lines(base_ary, s: s, i: i, config: config, info: info,
                                                 insertion: ctx[:insertion], param_types: ctx[:param_types])
        useful = line_ary.reject { |l| l.strip == '#' }
        return '' if useful.empty?

        line_ary.map { |l| "#{l}\n" }.join
      end

      # Build initial line ary
      #
      # @note module_function: defines #build_initial_line_ary (visibility: private)
      # @param [Array<String>] existing_lines existing doc comment lines being merged
      # @param [String] indent indentation string for the doc line
      # @return [Array<String>]
      def build_initial_line_ary(existing_lines, indent)
        existing_lines.any? && existing_lines.last.strip != '#' ? ["#{indent}#"] : []
      end

      # Merge all tag lines
      #
      # @note module_function: defines #merge_all_tag_lines (visibility: private)
      # @param [Array<String>] base_ary initial line array
      # @param [Hash<Symbol, Object>] ctx context hash with setup, config, info, insertion, param_types
      # @return [Array<String>]
      def merge_all_tag_lines(base_ary, **ctx)
        line_ary = base_ary.dup
        merge_tag_lines_core(line_ary, ctx)
        line_ary.concat(merge_rescue_return_lines(ctx[:i], ctx[:s][:rescue_specs], ctx[:config], ctx[:info]))
        line_ary
      end

      # Merge tag lines core
      #
      # @note module_function: defines #merge_tag_lines_core (visibility: private)
      # @param [Array<String>] line_ary output line array
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def merge_tag_lines_core(line_ary, ctx)
        append_merge_tag_lines(line_ary, ctx)
        merge_return_line(line_ary, ctx[:i], ctx[:s], ctx[:config], ctx[:info])
      end

      # Append merge tag lines
      #
      # @note module_function: defines #append_merge_tag_lines (visibility: private)
      # @param [Array<String>] line_ary output line array
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def append_merge_tag_lines(line_ary, ctx)
        line_ary.concat(build_all_merge_tags(ctx))
      end

      # Build all merge tags
      #
      # @note module_function: defines #build_all_merge_tags (visibility: private)
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [Array<String>]
      def build_all_merge_tags(ctx)
        i = ctx[:i]
        s = ctx[:s]
        c = ctx[:config]
        info = ctx[:info]
        [merge_visibility_tag_lines(i, s[:visibility], c, info),
         merge_module_function_note_lines(i, ctx[:insertion], s[:name], info),
         merge_param_lines(s[:node], i, config: c, external_sig: s[:external_sig],
                                        param_types: ctx[:param_types], info: info),
         merge_raise_tag_lines(s[:node], i, c, info)].flatten
      end

      # Merge return line
      #
      # @note module_function: defines #merge_return_line (visibility: private)
      # @param [Array<String>] line_ary output line array
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with node, name, types, scope
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash to update with visibility flags
      # @return [void]
      def merge_return_line(line_ary, indent, setup, config, info)
        emit_ret = config.emit_return_tag?(setup[:scope], setup[:visibility])
        ret_line = merge_return_tag_line(indent, setup[:normal_type], config: config, scope: setup[:scope],
                                                                      visibility: setup[:visibility], info: info)

        line_ary << ret_line if emit_ret && ret_line
      end

      # Collect all missing
      #
      # @note module_function: defines #collect_all_missing (visibility: private)
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup resolved setup hash with node, name, indent, types
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parsed existing doc tag information
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] options additional options hash forwarded to missing collector
      # @return [Docscribe::InlineRewriter::DocBuilder::missingMergeResult]
      def collect_all_missing(setup, info, insertion, config, options)
        s = setup
        ctx = { node: s[:node], indent: s[:indent], config: config, external_sig: s[:external_sig],
                info: info, strategy: options[:strategy], scope: s[:scope], visibility: s[:visibility],
                normal_type: s[:normal_type], rescue_specs: s[:rescue_specs], insertion: insertion,
                param_types: options[:param_types], override_tags: options[:override_tags] }
        collect_missing_all(ctx)
      end

      # Collect missing all
      #
      # @note module_function: defines #collect_missing_all (visibility: private)
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [Docscribe::InlineRewriter::DocBuilder::missingMergeResult]
      def collect_missing_all(ctx)
        lines = [] #: Array[String]
        reasons = [] #: Array[Hash[Symbol, untyped]]
        collect_missing_visibility!(lines, reasons, **ctx)
        collect_missing_module_function_note!(lines, reasons, **ctx)
        collect_missing_params!(lines, reasons, **ctx)
        collect_missing_raises!(lines, reasons, **ctx)
        collect_missing_return!(lines, reasons, **ctx)
        collect_missing_rescue_returns!(lines, reasons, **ctx)
        collect_missing_plugin_tags!(lines, reasons, **ctx)
        { lines: lines, reasons: reasons }
      end

      # Extract param info
      #
      # @note module_function: defines #extract_all_comment_tags (visibility: private)
      # @param [String] line single comment line
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash
      # @return [void]
      def extract_all_comment_tags(line, info)
        extract_param_info(line, info[:param_names], info[:param_types], info[:param_descriptions])
        extract_return_info(line, info)
        extract_visibility_info(line, info)
        extract_raise_info(line, info[:raise_types])
        extract_plugin_info(line, info[:plugin_tags])
      end

      # Extract param info from tag line
      #
      # @note module_function: defines #extract_param_info (visibility: private)
      # @param [String] line a single doc comment line to parse
      # @param [Hash<String, Boolean>] param_names hash tracking existing @param names
      # @param [Hash<String, String>] param_types hash tracking existing @param types
      # @param [Hash<String, String>, nil] param_descriptions param descriptions hash
      # @return [void]
      def extract_param_info(line, param_names, param_types, param_descriptions = nil)
        return unless (pname = extract_param_name_from_param_line(line))

        param_names[pname] = true
        ptype = extract_param_type_from_param_line(line)
        return unless ptype

        param_types[pname] = ptype
        return unless param_descriptions

        desc = extract_param_description(line)
        param_descriptions[pname] = desc if desc
      end

      # Extract return info
      #
      # @note module_function: defines #extract_return_info (visibility: private)
      # @param [String] line a single doc comment line to parse
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash to update with return data
      # @return [void]
      def extract_return_info(line, info)
        return unless line.match?(/^\s*#\s*@return\b/)

        info[:has_return] = true
        content = line.sub(/^\s*#\s*/, '')
        return unless (m = content.match(/@return\s+/))

        return_type, return_desc = parse_return_rest(m.post_match)
        return unless return_type
        # Rescue-conditional `@return [X] if Error` tags describe rescue
        # branches (see rescue_conditional_returns) and must not overwrite
        # the main return type — otherwise check demands the conditional
        # type while update_types regenerates it, ping-ponging forever.
        return if conditional_return_desc?(return_desc)

        info[:return_type] = return_type
        info[:return_description] = return_desc if return_desc
      end

      # Whether a return description marks a rescue-conditional tag.
      #
      # @note module_function: defines #conditional_return_desc? (visibility: private)
      # @param [String, nil] desc description after the type brackets
      # @return [Boolean] true for "if Error" suffixes
      def conditional_return_desc?(desc)
        desc.to_s.start_with?('if ')
      end

      # Parse return type from rest string
      #
      # @note module_function: defines #parse_return_rest (visibility: private)
      # @param [String] rest remaining tag content
      # @return [(String, String, nil), nil]
      def parse_return_rest(rest)
        return unless rest[0] == '['

        type_end = find_matching_close_bracket(rest) or return

        return_type = rest[1...type_end] #: String
        desc = rest[(type_end + 1)..]&.strip
        [return_type, desc && desc.empty? ? nil : desc]
      end

      # Extract all comment tags from line
      #
      # @note module_function: defines #track_last_tag (visibility: private)
      # @param [String] content
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash
      # @return [void]
      def track_last_tag(content, info)
        tag = content.match(/@(\w+)/)&.[](1)&.to_sym
        info[:last_tag] = tag
        return unless tag == :param

        pname = extract_param_name_from_param_line(content)
        info[:last_param] = pname if pname
      end

      # Append continuation to current tag
      #
      # @note module_function: defines #append_tag_continuation (visibility: private)
      # @param [String] content tag continuation text
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash
      # @return [void]
      def append_tag_continuation(content, info)
        text = content.strip
        return if text.empty?

        append_to_return_description(text, info) if info[:last_tag] == :return
        append_to_param_description(text, info) if info[:last_tag] == :param
      end

      # Append text to return description
      #
      # @note module_function: defines #append_to_return_description (visibility: private)
      # @param [String] text text to append
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash
      # @return [void]
      def append_to_return_description(text, info)
        if info[:return_description]
          info[:return_description] += "\n#{text}"
        else
          info[:return_description] = text
        end
      end

      # Append text to param description
      #
      # @note module_function: defines #append_to_param_description (visibility: private)
      # @param [String] text text to append
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash
      # @return [void]
      def append_to_param_description(text, info)
        pname = info[:last_param]
        return unless pname

        if info[:param_descriptions][pname]
          info[:param_descriptions][pname] += "\n#{text}"
        else
          info[:param_descriptions][pname] = text
        end
      end

      # Extract visibility info
      #
      # @note module_function: defines #extract_visibility_info (visibility: private)
      # @param [String] line a single doc comment line to parse
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash to update with visibility flags
      # @return [void]
      def extract_visibility_info(line, info)
        info[:has_private] ||= line.match?(/^\s*#\s*@private\b/)
        info[:has_protected] ||= line.match?(/^\s*#\s*@protected\b/)
        info[:has_module_function_note] ||= line.match?(/^\s*#\s*@note\s+module_function:/)
      end

      # Extract raise info
      #
      # @note module_function: defines #extract_raise_info (visibility: private)
      # @param [String] line a single doc comment line to parse
      # @param [Hash<String, Boolean>] raise_types hash tracking existing @raise types
      # @return [void]
      def extract_raise_info(line, raise_types)
        extract_raise_types_from_line(line).each { |t| raise_types[t || ''] = true }
      end

      # Extract plugin info
      #
      # @note module_function: defines #extract_plugin_info (visibility: private)
      # @param [String] line a single doc comment line to parse
      # @param [Hash<String, Boolean>] plugin_tags hash tracking existing plugin tag names
      # @return [void]
      def extract_plugin_info(line, plugin_tags)
        return unless (m = line.match(/^\s*#\s*@(\w+)\b/))

        plugin_tags[m[1] || ''] = true
      end

      # Extract raise types from line
      #
      # @note module_function: defines #extract_raise_types_from_line (visibility: private)
      # @param [String] line a `@raise` doc line
      # @raise [StandardError]
      # @return [Array<String, nil>]
      # @return [Array] if StandardError
      def extract_raise_types_from_line(line)
        return [] unless line.match?(/^\s*#\s*@raise\b/)

        bracketed_raise_types(line) || bare_raise_type(line) || []
      rescue StandardError
        []
      end

      # Bracketed raise types from line
      #
      # @note module_function: defines #bracketed_raise_types (visibility: private)
      # @param [String] line a `@raise` doc line
      # @return [Array<String>, nil]
      def bracketed_raise_types(line)
        m = line.match(/^\s*#\s*@raise\s*\[([^\]]+)\]/)
        return nil unless m

        captured = m[1]
        captured ? parse_raise_bracket_list(captured) : []
      end

      # Bare raise type from line
      #
      # @note module_function: defines #bare_raise_type (visibility: private)
      # @param [String] line a `@raise` doc line
      # @return [String, nil]
      def bare_raise_type(line)
        m = line.match(/^\s*#\s*@raise\s+([A-Z]\w*(?:::[A-Z]\w*)*)/)
        return nil unless m

        captured = m[1]
        captured ? [captured] : []
      end

      # Parse raise bracket list
      #
      # @note module_function: defines #parse_raise_bracket_list (visibility: private)
      # @param [String] str comma-separated exception names string from @raise brackets
      # @return [Array<String>] the exception names or nil
      def parse_raise_bracket_list(str)
        str.to_s.split(',').map(&:strip).reject(&:empty?)
      end

      # Build param types from node
      #
      # @note module_function: defines #build_param_types_from_node (visibility: private)
      # @param [Parser::AST::Node] node def or defs node
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external signature if available
      # @param [Docscribe::Config] config Docscribe configuration object
      # @return [Hash<String, String>, nil]
      def build_param_types_from_node(node, external_sig:, config:)
        return unless node

        args = extract_args_from_node(node)
        return unless args

        param_types = {} #: Hash[String, String]
        collect_all_param_types(args, param_types, external_sig, config)
        param_types.empty? ? nil : param_types
      end

      # Collect all param types
      #
      # @note module_function: defines #collect_all_param_types (visibility: private)
      # @param [Parser::AST::Node] args arguments AST node
      # @param [Hash<String, String>] param_types hash accumulating parameter name-to-type mappings
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Docscribe::Config] config Docscribe configuration object
      # @return [void]
      def collect_all_param_types(args, param_types, external_sig, config)
        # Pre-seed param_types with positional (unnamed) RBS types so that
        # collectors can keep them when external_sig lacks param names.
        positional = Array(external_sig&.positional_types)
        (args.children || []).each_with_index do |a, idx|
          if (ptype = positional[idx])
            pname = a.children.first
            param_types[pname.to_s] = ptype if pname
          end
          collector = PARAM_TYPE_COLLECTORS[a.type]
          collector&.call(a, param_types, external_sig, config)
        end
      end

      # Collect param type
      #
      # @note module_function: defines #collect_param_type (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the required/keyword argument
      # @param [Hash<String, String>] param_types hash accumulating parameter name-to-type mappings
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Docscribe::Config] config Docscribe configuration for fallback type options
      # @param [Proc, nil] infer_name lambda to transform parameter name for inference
      # @return [void]
      def collect_param_type(arg_node, param_types, external_sig, config, infer_name:)
        pname = arg_node.children.first.to_s
        param_types[pname] ||= begin
          infer_pname = resolve_infer_name(pname, infer_name)
          external_sig&.param_types&.[](pname) ||
            Infer.infer_param_type(infer_pname, nil,
                                   fallback_type: config.fallback_type,
                                   treat_options_keyword_as_hash: config.treat_options_keyword_as_hash?)
        end
      end

      # Collect optarg param type
      #
      # @note module_function: defines #collect_optarg_param_type (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the optional/keyword optional argument
      # @param [Hash<String, String>] param_types hash accumulating parameter name-to-type mappings
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Docscribe::Config] config Docscribe configuration for fallback type options
      # @param [Proc, nil] infer_name lambda to transform parameter name for inference
      # @return [void]
      def collect_optarg_param_type(arg_node, param_types, external_sig, config, infer_name:)
        pname, default = *arg_node
        pname = pname.to_s
        param_types[pname] ||= begin
          default_src = source_from_node(default)
          infer_pname = resolve_infer_name(pname, infer_name)
          external_sig&.param_types&.[](pname) ||
            Infer.infer_param_type(infer_pname, default_src,
                                   fallback_type: config.fallback_type,
                                   treat_options_keyword_as_hash: config.treat_options_keyword_as_hash?)
        end
      end

      # Merge visibility tag lines
      #
      # @note module_function: defines #merge_visibility_tag_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Symbol] visibility method visibility symbol
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash to update with visibility flags
      # @return [Array<String>]
      def merge_visibility_tag_lines(indent, visibility, config, info)
        return [] unless config.emit_visibility_tags?

        if visibility == :private && !info[:has_private]
          ["#{indent}# @private"]
        elsif visibility == :protected && !info[:has_protected]
          ["#{indent}# @protected"]
        else
          []
        end
      end

      # Merge module function note lines
      #
      # @note module_function: defines #merge_module_function_note_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [String] name the method name string
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash to update with visibility flags
      # @return [Array<String>]
      def merge_module_function_note_lines(indent, insertion, name, info)
        return [] unless insertion.respond_to?(:module_function) && insertion.module_function && !info[:has_module_function_note]

        included_vis = insertion.included_instance_visibility || :private
        ["#{indent}# @note module_function: defines ##{name} (visibility: #{included_vis})"]
      end

      # Merge param lines
      #
      # @note module_function: defines #merge_param_lines (visibility: private)
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @param [String] indent indentation string for the doc line
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] opts additional options including external_sig, param_types, info
      # @return [Array<String>]
      def merge_param_lines(node, indent, config:, **opts)
        return [] unless config.emit_param_tags?

        all_params = build_params_lines(node, indent, external_sig: opts[:external_sig], config: config,
                                                      param_types_override: opts[:param_types])
        return [] unless all_params

        info = opts[:info]
        all_params.each_with_object([]) do |pl, result|
          pname = extract_param_name_from_param_line(pl)
          next if pname.nil? || info[:param_names].include?(pname)

          result << pl
        end
      end

      # Merge raise tag lines
      #
      # @note module_function: defines #merge_raise_tag_lines (visibility: private)
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @param [String] indent indentation string for the doc line
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash to update with visibility flags
      # @return [Array<String>]
      def merge_raise_tag_lines(node, indent, config, info)
        return [] unless config.emit_raise_tags?

        inferred = Docscribe::Infer.infer_raises_from_node(node)
        existing = info[:raise_types] || {}
        inferred.reject { |rt| existing[rt] }
                .map { |rt| "#{indent}# @raise [#{rt}]" }
      end

      # Merge return tag line
      #
      # @note module_function: defines #merge_return_tag_line (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [String] normal_type resolved return type
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] opts additional options including scope, visibility, info
      # @return [String, nil]
      def merge_return_tag_line(indent, normal_type, config:, **opts)
        return unless config.emit_return_tag?(opts[:scope], opts[:visibility])
        return if opts[:info][:has_return]

        "#{indent}# @return [#{normal_type}]"
      end

      # Merge rescue return lines
      #
      # @note module_function: defines #merge_rescue_return_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Array<(Array<String>, String)>] rescue_specs rescue type specs
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Docscribe::InlineRewriter::DocBuilder::parseInfo] info parse info hash to update with visibility flags
      # @return [Array<String>]
      def merge_rescue_return_lines(indent, rescue_specs, config, info)
        return [] unless config.emit_rescue_conditional_returns?
        return [] if info[:has_return]

        rescue_specs.filter_map do |exceptions, rtype|
          next unless informative_rescue_type?(rtype)

          "#{indent}# @return [#{rtype}] if #{exceptions.join(', ')}"
        end
      end

      # Collect missing visibility
      #
      # @note module_function: defines #collect_missing_visibility! (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def collect_missing_visibility!(lines, reasons, **ctx)
        return unless ctx[:config].emit_visibility_tags?

        add_missing_private(lines, reasons, ctx)
        add_missing_protected(lines, reasons, ctx)
      end

      # Add missing private
      #
      # @note module_function: defines #add_missing_private (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def add_missing_private(lines, reasons, ctx)
        return unless ctx[:visibility] == :private && !ctx[:info][:has_private]

        lines << "#{ctx[:indent]}# @private\n"
        reasons << { type: :missing_visibility, message: 'missing @private' }
      end

      # Add missing protected
      #
      # @note module_function: defines #add_missing_protected (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def add_missing_protected(lines, reasons, ctx)
        return unless ctx[:visibility] == :protected && !ctx[:info][:has_protected]

        lines << "#{ctx[:indent]}# @protected\n"
        reasons << { type: :missing_visibility, message: 'missing @protected' }
      end

      # Collect missing module function note
      #
      # @note module_function: defines #collect_missing_module_function_note! (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def collect_missing_module_function_note!(lines, reasons, **ctx)
        insertion = ctx[:insertion]
        unless insertion.respond_to?(:module_function) && insertion.module_function &&
               !ctx[:info][:has_module_function_note]
          return
        end

        included_vis = insertion.included_instance_visibility || :private
        lines << "#{ctx[:indent]}# @note module_function: defines ##{ctx[:name]} (visibility: #{included_vis})\n"
        reasons << { type: :missing_module_function_note, message: 'missing module_function note' }
      end

      # Collect missing params
      #
      # @note module_function: defines #collect_missing_params! (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def collect_missing_params!(lines, reasons, **ctx)
        return unless ctx[:config].emit_param_tags?

        all_params = build_params_lines(ctx[:node], ctx[:indent],
                                        external_sig: ctx[:external_sig], config: ctx[:config],
                                        param_types_override: ctx[:param_types])
        return unless all_params

        all_params.each { |pl| collect_param_from_line(pl, lines, reasons, ctx) }
      end

      # Collect param from line
      #
      # @note module_function: defines #collect_param_from_line (visibility: private)
      # @param [String] param_line a single @param tag line to evaluate
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with build parameters
      # @return [void]
      def collect_param_from_line(param_line, lines, reasons, ctx)
        pname = extract_param_name_from_param_line(param_line)
        return unless pname

        if missing_param?(pname, ctx)
          handle_missing_param(pname, param_line, lines, reasons)
        elsif existing_param_type?(pname, ctx)
          handle_existing_param(pname, param_line, lines, reasons, ctx)
        end
      end

      # @note module_function: defines #missing_param? (visibility: private)
      # @param [String] pname
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def missing_param?(pname, ctx)
        !ctx[:info][:param_names].include?(pname)
      end

      # @note module_function: defines #existing_param_type? (visibility: private)
      # @param [String] pname
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def existing_param_type?(pname, ctx)
        !!ctx[:info][:param_types][pname]
      end

      # @note module_function: defines #handle_missing_param (visibility: private)
      # @param [String] pname
      # @param [String] param_line
      # @param [Array<String>] lines
      # @param [Array<Hash<Symbol, Object>>] reasons
      # @return [void]
      def handle_missing_param(pname, param_line, lines, reasons)
        lines << "#{param_line}\n"
        reasons << { type: :missing_param, message: "missing @param #{pname}", extra: { param: pname } }
      end

      # @note module_function: defines #handle_existing_param (visibility: private)
      # @param [String] pname
      # @param [String] param_line
      # @param [Array<String>] lines
      # @param [Array<Hash<Symbol, Object>>] reasons
      # @param [Hash<Symbol, Object>] ctx
      # @return [void]
      def handle_existing_param(pname, param_line, lines, reasons, ctx)
        yard_type = ctx[:info][:param_types][pname]
        if invalid_yard_type?(yard_type)
          handle_invalid_param(pname, param_line, yard_type, lines, reasons)
        elsif param_needs_update?(ctx)
          collect_updated_param(param_line, pname, lines, reasons, ctx)
        end
      end

      # @note module_function: defines #handle_invalid_param (visibility: private)
      # @param [String] pname
      # @param [String] param_line
      # @param [String] yard_type
      # @param [Array<String>] lines
      # @param [Array<Hash<Symbol, Object>>] reasons
      # @return [void]
      def handle_invalid_param(pname, param_line, yard_type, lines, reasons)
        lines << "#{param_line}\n"
        reasons << {
          type: :invalid_type,
          message: "invalid YARD type [#{yard_type}] for @param #{pname}",
          source: 'syntax',
          extra: { param: pname }
        }
      end

      # @note module_function: defines #param_needs_update? (visibility: private)
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def param_needs_update?(ctx)
        should_validate_param?(ctx) || !!ctx[:external_sig]
      end

      # Whether a YARD type string has invalid syntax.
      #
      # @note module_function: defines #invalid_yard_type? (visibility: private)
      # @param [String?] type_str
      # @return [Boolean]
      def invalid_yard_type?(type_str) # rubocop:disable SortedMethodsByCall/Waterfall
        return false if type_str.nil? || type_str.strip.empty?
        return true if type_str.match?(/\d/)
        return true if type_str.match?(/[^\x00-\x7F]/)

        !Types::Yard::Validator.valid?(type_str)
      end

      # Whether param validation should run via inferred/external types.
      #
      # @note module_function: defines #should_validate_param? (visibility: private)
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def should_validate_param?(ctx)
        ctx[:config].respond_to?(:validate_types?) && ctx[:config].validate_types?
      end

      # Collect updated param
      #
      # @note module_function: defines #collect_updated_param (visibility: private)
      # @param [String] param_line a single @param tag line to evaluate
      # @param [String] pname the parameter name string
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with build parameters
      # @return [void]
      def collect_updated_param(param_line, pname, lines, reasons, ctx)
        new_type = extract_param_type_from_param_line(param_line)
        return unless param_type_changed?(pname, new_type, ctx)
        return if fallback_skipped?(new_type, ctx)

        append_param_update(param_line, pname, new_type, lines, reasons, ctx)
      end

      # @note module_function: defines #param_type_changed? (visibility: private)
      # @param [String] pname
      # @param [String, nil] new_type
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def param_type_changed?(pname, new_type, ctx)
        yard = ctx[:info][:param_types][pname]
        return false unless new_type && yard
        return false if normalize_type(yard) == normalize_type(new_type)
        return false if generic_compatible?(yard, new_type)

        yard != new_type
      end

      # @note module_function: defines #fallback_skipped? (visibility: private)
      # @param [String, nil] new_type
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def fallback_skipped?(new_type, ctx)
        ctx[:config].respond_to?(:validate_types?) && ctx[:config].validate_types? && (new_type == ctx[:config].fallback_type)
      end

      # @note module_function: defines #append_param_update (visibility: private)
      # @param [String] param_line
      # @param [String] pname
      # @param [String, nil] new_type
      # @param [Array<String>] lines
      # @param [Array<Hash<Symbol, Object>>] reasons
      # @param [Hash<Symbol, Object>] ctx
      # @return [void]
      def append_param_update(param_line, pname, new_type, lines, reasons, ctx) # rubocop:disable Metrics/ParameterLists
        lines << "#{param_line}\n" unless ctx[:strategy] == :safe
        reasons << {
          type: :updated_param,
          message: "updated @param #{pname} from #{ctx[:info][:param_types][pname]} to #{new_type}",
          source: ctx[:external_sig] ? 'rbs' : 'infer',
          extra: { param: pname }
        }
      end

      # Build params lines
      #
      # @note module_function: defines #build_params_lines (visibility: private)
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @param [String] indent indentation string for the doc line
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash] kwargs additional keyword args including insertion, params_lines, raise_types, override_tags
      # @return [Array<String>, nil]
      def build_params_lines(node, indent, external_sig:, config:, **kwargs)
        args = extract_args_from_node(node)
        return nil unless args

        build_all_param_lines(args, indent, config, external_sig: external_sig, **kwargs)
      end

      # Build all param lines
      #
      # @note module_function: defines #build_all_param_lines (visibility: private)
      # @param [Parser::AST::Node] args arguments AST node
      # @param [String] indent indentation string for the doc line
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<Symbol, Object>] kwargs additional keyword args including insertion, params_lines, raise_types, override_tags
      # @return [Array<String>, nil]
      def build_all_param_lines(args, indent, config, external_sig: nil, **kwargs)
        param_lines = [] #: Array[String]
        params = (args.children || []).each_with_object(param_lines) do |a, p|
          p.concat(build_param_line(a, indent, external_sig, kwargs[:param_types_override],
                                    skip_anonymous_block_params: config.skip_anonymous_block_params?,
                                    fallback_type: config.fallback_type,
                                    treat_options_keyword_as_hash: config.treat_options_keyword_as_hash?,
                                    param_documentation: param_doc_for_arg(a, kwargs, config),
                                    param_tag_style: config.param_tag_style))
        end
        params.empty? ? nil : params
      end

      # Get param doc for argument
      #
      # @note module_function: defines #param_doc_for_arg (visibility: private)
      # @param [Parser::AST::Node] arg individual argument node
      # @param [Hash<Symbol, Object>] kwargs keyword args hash
      # @param [Docscribe::Config] config doc configuration
      # @return [String]
      def param_doc_for_arg(arg, kwargs, config)
        (kwargs[:param_descriptions] || {})[param_name_from_arg(arg)] ||
          (config.include_param_documentation? ? config.param_documentation : '')
      end

      # Build doc lines
      #
      # @note module_function: defines #build_doc_lines (visibility: private)
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with indent, name, types, scope
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] kwargs additional keyword args including insertion, params_lines, raise_types, override_tags
      # @return [Array<String>]
      def build_doc_lines(setup, config:, **kwargs)
        i = setup[:indent]
        assemble_doc_lines(i, setup, config: config, insertion: kwargs[:insertion],
                                     params_lines: kwargs[:params_lines],
                                     raise_types: kwargs[:raise_types], override_tags: kwargs[:override_tags],
                                     return_description: kwargs[:return_description],
                                     description: kwargs[:description])
      end

      # Assemble doc lines
      #
      # @note module_function: defines #assemble_doc_lines (visibility: private)
      # @param [String] indent indent
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup setup
      # @param [Hash<Symbol, Object>] ctx context hash with config, insertion, params_lines, raise_types, override_tags
      # @return [Array<String>]
      def assemble_doc_lines(indent, setup, **ctx)
        line_ary = build_header_lines(
          indent,
          config: ctx[:config],
          container: setup[:container], method_symbol: setup[:method_symbol], name: setup[:name],
          normal_type: setup[:normal_type]
        )

        append_assemble_body_lines(line_ary, indent, setup, ctx)
        line_ary
      end

      # Append assemble body lines
      #
      # @note module_function: defines #append_assemble_body_lines (visibility: private)
      # @param [Array<String>] line_ary output line array
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with name, types, scope
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def append_assemble_body_lines(line_ary, indent, setup, ctx)
        line_ary.concat(build_all_body_tags(indent, setup, ctx))
      end

      # Build all body tags
      #
      # @note module_function: defines #build_all_body_tags (visibility: private)
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with name, types, scope
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [Array<String>]
      def build_all_body_tags(indent, setup, ctx)
        result = core_body_tags(indent, setup, ctx)
        result.insert(4, ctx[:params_lines]) if ctx[:params_lines]
        result.flatten
      end

      # Core body tags
      #
      # @note module_function: defines #core_body_tags (visibility: private)
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with name, types, scope
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [Array<String>]
      def core_body_tags(indent, setup, ctx)
        config, insertion = ctx.values_at(:config, :insertion)
        [
          defaults_and_visibility(indent, config, setup[:scope], setup[:visibility], description: ctx[:description]),
          build_module_function_note_lines(indent, insertion, setup[:name]),
          ctx.dig(:info, :note_lines) || [],
          build_raise_tag_lines(indent, ctx[:raise_types], config),
          build_return_line_if_needed(indent, setup, config, ctx),
          build_rescue_return_lines(indent, setup[:rescue_specs], config),
          build_plugin_tag_lines(insertion, indent, setup[:normal_type], ctx[:override_tags])
        ]
      end

      # Defaults and visibility
      #
      # @note module_function: defines #defaults_and_visibility (visibility: private)
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Symbol] scope method scope symbol
      # @param [Symbol] visibility method visibility symbol
      # @param [Array<String>, nil] description optional description lines
      # @return [Array<String>]
      def defaults_and_visibility(indent, config, scope, visibility, description: nil)
        [
          build_default_msg_lines(indent, config, scope, visibility, description: description),
          build_visibility_tag_lines(indent, visibility, config)
        ].flatten
      end

      # Build return line if needed
      #
      # @note module_function: defines #build_return_line_if_needed (visibility: private)
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::InlineRewriter::DocBuilder::setup] setup method setup hash with name, normal_type, scope, visibility
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [Array<String>]
      def build_return_line_if_needed(indent, setup, config, ctx)
        ret_line = build_return_tag_line(indent, setup[:normal_type], config, setup[:scope], setup[:visibility])
        rd = ctx[:return_description]
        if ret_line && rd && !rd.empty?
          lines = rd.split("\n")
          ret_line = +"#{ret_line} #{lines.first}"
          lines[1..]&.each { |l| ret_line << "\n#{indent}#   #{l}" }
        end
        ret_line ? [ret_line] : []
      end

      # Extract args from node
      #
      # @note module_function: defines #extract_args_from_node (visibility: private)
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @return [Parser::AST::Node, nil]
      def extract_args_from_node(node)
        case node.type
        when :def then node.children[1]
        when :defs then node.children[2]
        end
      end

      # Build param line
      #
      # @note module_function: defines #build_param_line (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the argument
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options for param formatting (fallback_type, param_tag_style, etc.)
      # @return [Array<String>]
      def build_param_line(arg_node, indent, external_sig, param_types_override, **opts)
        method_name = :"build_#{arg_node.type}_line"
        if respond_to?(method_name, true)
          return [] if arg_node.type == :blockarg && opts[:skip_anonymous_block_params] && arg_node.children.first.nil?

          return [send(method_name, arg_node, indent, external_sig, param_types_override, **opts)]
        end

        method_name = :"build_#{arg_node.type}_lines"
        return send(method_name, arg_node, indent, external_sig, param_types_override, **opts) if respond_to?(method_name, true)

        []
      end

      # Build header lines
      #
      # @note module_function: defines #build_header_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Hash<Symbol, Object>] opts additional options including container, method_symbol, name, normal_type
      # @return [Array<String>]
      def build_header_lines(indent, config:, **opts)
        if config.emit_header?
          c = opts[:container]
          ms = opts[:method_symbol]
          n = opts[:name]
          nt = opts[:normal_type]
          ["#{indent}# +#{c}#{ms}#{n}+ -> #{nt}", "#{indent}#"]
        else
          []
        end
      end

      # Build default msg lines
      #
      # @note module_function: defines #build_default_msg_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Symbol] scope method scope symbol
      # @param [Symbol] visibility method visibility symbol
      # @param [Array<String>, nil] description optional description lines
      # @return [Array<String>]
      def build_default_msg_lines(indent, config, scope, visibility, description: nil)
        if description&.any?
          result = description.map { |line| line.empty? ? "#{indent}#" : "#{indent}# #{line}" }
          result << "#{indent}#" unless result.last == "#{indent}#"
          result
        elsif config.include_default_message?
          ["#{indent}# #{config.default_message(scope, visibility)}", "#{indent}#"]
        else
          []
        end
      end

      # Build visibility tag lines
      #
      # @note module_function: defines #build_visibility_tag_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Symbol] visibility method visibility symbol
      # @param [Docscribe::Config] config Docscribe configuration object
      # @return [Array<String>]
      def build_visibility_tag_lines(indent, visibility, config)
        return [] unless config.emit_visibility_tags?

        case visibility
        when :private then ["#{indent}# @private"]
        when :protected then ["#{indent}# @protected"]
        else []
        end
      end

      # Build module function note lines
      #
      # @note module_function: defines #build_module_function_note_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [String] name the method name string
      # @return [Array<String>]
      def build_module_function_note_lines(indent, insertion, name)
        return [] unless insertion.respond_to?(:module_function) && insertion.module_function

        included_vis =
          if insertion.respond_to?(:included_instance_visibility) && insertion.included_instance_visibility
            insertion.included_instance_visibility
          else
            :private
          end

        ["#{indent}# @note module_function: defines ##{name} (visibility: #{included_vis})"]
      end

      # Build raise tag lines
      #
      # @note module_function: defines #build_raise_tag_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Array<String>] raise_types hash tracking existing @raise types
      # @param [Docscribe::Config] config Docscribe configuration object
      # @return [Array<String>]
      def build_raise_tag_lines(indent, raise_types, config)
        return [] unless config.emit_raise_tags?

        raise_types.map { |rt| "#{indent}# @raise [#{rt}]" }
      end

      # Build return tag line
      #
      # @note module_function: defines #build_return_tag_line (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [String] normal_type resolved return type
      # @param [Docscribe::Config] config Docscribe configuration object
      # @param [Symbol] scope method scope symbol
      # @param [Symbol] visibility method visibility symbol
      # @return [String, nil]
      def build_return_tag_line(indent, normal_type, config, scope, visibility)
        return unless config.emit_return_tag?(scope, visibility)

        "#{indent}# @return [#{normal_type}]"
      end

      # Build rescue return lines
      #
      # @note module_function: defines #build_rescue_return_lines (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [Array<(Array<String>, String)>] rescue_specs rescue type specs
      # @param [Docscribe::Config] config Docscribe configuration object
      # @return [Array<String>]
      def build_rescue_return_lines(indent, rescue_specs, config)
        return [] unless config.emit_rescue_conditional_returns?

        rescue_specs.filter_map do |exceptions, rtype|
          next unless informative_rescue_type?(rtype)

          "#{indent}# @return [#{rtype}] if #{exceptions.join(', ')}"
        end
      end

      # Whether a rescue-branch type is worth documenting.
      #
      # Bare fallback (`Object`, blank) carries no information ("unknown on
      # error") — emitting it only churns hand-written conditionals into
      # noise on every aggressive rebuild.
      #
      # @note module_function: defines #informative_rescue_type? (visibility: private)
      # @param [String, nil] rtype inferred rescue-branch type
      # @return [Boolean] true if the type should be emitted
      def informative_rescue_type?(rtype)
        norm = normalize_type(rtype)
        !norm.empty? && norm != 'Object'
      end

      # Build plugin tag lines
      #
      # @note module_function: defines #build_plugin_tag_lines (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [String] indent indentation string for the doc line
      # @param [String] normal_type resolved return type
      # @param [Array<Docscribe::Plugin::Tag>, nil] override_tags plugin tag overrides
      # @return [Array<String>]
      def build_plugin_tag_lines(insertion, indent, normal_type, override_tags)
        plugin_tags = Docscribe::Plugin.run_tag_plugins(build_plugin_context(insertion, normal_type: normal_type))
        plugin_tags.concat(Array(override_tags)) if override_tags
        render_plugin_tags(plugin_tags, indent)
      end

      # Build arg line
      #
      # @note module_function: defines #build_arg_line (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the required argument
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options for param formatting
      # @return [String]
      def build_arg_line(arg_node, indent, external_sig, param_types_override, **opts)
        pname = arg_node.children.first.to_s
        ty = lookup_param_type(external_sig, param_types_override, pname, pname,
                               infer_default: nil,
                               fallback_type: opts[:fallback_type],
                               treat_options_keyword_as_hash: opts[:treat_options_keyword_as_hash])
        format_param_tag(indent, pname, ty, opts[:param_documentation], style: opts[:param_tag_style])
      end

      # Build optarg lines
      #
      # @note module_function: defines #build_optarg_lines (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the optional argument
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options for param formatting
      # @return [Array<String>]
      def build_optarg_lines(arg_node, indent, external_sig, param_types_override, **opts)
        pname, default = *arg_node
        pname = pname.to_s
        ty = optarg_type(pname, default, external_sig, param_types_override, opts)
        lines = [format_param_tag(indent, pname, ty, opts[:param_documentation], style: opts[:param_tag_style])]

        append_option_lines(lines, default, indent, pname, opts[:fallback_type])
        lines
      end

      # Optarg type
      #
      # @note module_function: defines #optarg_type (visibility: private)
      # @param [String] pname the parameter name to look up
      # @param [Parser::AST::Node] default default value node
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options including
      # @return [String]
      def optarg_type(pname, default, external_sig, param_types_override, opts)
        default_src = source_from_node(default)
        lookup_param_type(external_sig, param_types_override, pname, pname,
                          infer_default: default_src,
                          fallback_type: opts[:fallback_type],
                          treat_options_keyword_as_hash: opts[:treat_options_keyword_as_hash])
      end

      # Source from node
      #
      # @note module_function: defines #source_from_node (visibility: private)
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @return [String, nil]
      def source_from_node(node)
        loc = node&.loc
        loc&.expression&.source
      end

      # Resolve infer name
      #
      # @note module_function: defines #resolve_infer_name (visibility: private)
      # @param [String] pname the parameter name to look up
      # @param [Proc, nil] infer_name parameter name string or transformed version for inference
      # @return [String]
      def resolve_infer_name(pname, infer_name)
        infer_name ? infer_name.call(pname) : pname
      end

      # Build kwarg line
      #
      # @note module_function: defines #build_kwarg_line (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the keyword argument
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options for param formatting
      # @return [String]
      def build_kwarg_line(arg_node, indent, external_sig, param_types_override, **opts)
        pname = arg_node.children.first.to_s
        ty = lookup_param_type(external_sig, param_types_override, pname, "#{pname}:",
                               infer_default: nil,
                               fallback_type: opts[:fallback_type],
                               treat_options_keyword_as_hash: opts[:treat_options_keyword_as_hash])
        format_param_tag(indent, pname, ty, opts[:param_documentation], style: opts[:param_tag_style])
      end

      # Build kwoptarg line
      #
      # @note module_function: defines #build_kwoptarg_line (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the optional keyword argument
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options for param formatting
      # @return [String]
      def build_kwoptarg_line(arg_node, indent, external_sig, param_types_override, **opts)
        pname, default = *arg_node
        pname = pname.to_s
        default_loc = default&.loc
        default_src = default_loc&.expression&.source
        ty = lookup_param_type(external_sig, param_types_override, pname, "#{pname}:",
                               infer_default: default_src,
                               fallback_type: opts[:fallback_type],
                               treat_options_keyword_as_hash: opts[:treat_options_keyword_as_hash])
        format_param_tag(indent, pname, ty, opts[:param_documentation], style: opts[:param_tag_style])
      end

      # Build restarg line
      #
      # @note module_function: defines #build_restarg_line (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the rest argument (*args)
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options for param formatting
      # @return [String]
      def build_restarg_line(arg_node, indent, external_sig, param_types_override, **opts)
        pname = (arg_node.children.first || 'args').to_s
        rest_pos = external_sig&.rest_positional
        ty = if rest_pos&.element_type
               "Array<#{rest_pos.element_type}>"
             else
               lookup_param_type_by_infer(param_types_override, pname, "*#{pname}",
                                          opts[:fallback_type], opts[:treat_options_keyword_as_hash])
             end
        format_param_tag(indent, pname, ty, opts[:param_documentation], style: opts[:param_tag_style])
      end

      # Build kwrestarg line
      #
      # @note module_function: defines #build_kwrestarg_line (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the keyword rest argument (**kwargs)
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options for param formatting
      # @return [String]
      def build_kwrestarg_line(arg_node, indent, external_sig, param_types_override, **opts)
        pname = (arg_node.children.first || 'kwargs').to_s
        ty = external_sig&.rest_keywords&.type ||
             lookup_param_type_by_infer(param_types_override, pname, "**#{pname}",
                                        opts[:fallback_type], opts[:treat_options_keyword_as_hash])
        format_param_tag(indent, pname, ty, opts[:param_documentation], style: opts[:param_tag_style])
      end

      # Build blockarg line
      #
      # @note module_function: defines #build_blockarg_line (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the block argument (&block)
      # @param [String] indent indentation string for doc comment lines
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [Hash<Symbol, Object>] opts additional options for param formatting
      # @return [String]
      def build_blockarg_line(arg_node, indent, external_sig, param_types_override, **opts)
        pname = (arg_node.children.first || 'block').to_s
        ty = lookup_param_type(external_sig, param_types_override, pname, "&#{pname}",
                               infer_default: nil,
                               fallback_type: opts[:fallback_type],
                               treat_options_keyword_as_hash: opts[:treat_options_keyword_as_hash])
        format_param_tag(indent, pname, ty, opts[:param_documentation], style: opts[:param_tag_style])
      end

      # Lookup param type
      #
      # @note module_function: defines #lookup_param_type (visibility: private)
      # @param [Docscribe::Types::MethodSignature, nil] external_sig external method signature for type overrides
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [String] pname the parameter name string
      # @param [String] infer_name parameter name string or transformed version for inference
      # @param [Hash<Symbol, Object>] opts additional options including infer_default, fallback_type, treat_options_keyword_as_hash
      # @return [String]
      def lookup_param_type(external_sig, param_types_override, pname, infer_name, **opts)
        external_sig&.param_types&.[](pname) ||
          override_param_type_for(pname, param_types_override) ||
          Infer.infer_param_type(infer_name, opts[:infer_default],
                                 fallback_type: opts[:fallback_type],
                                 treat_options_keyword_as_hash: opts[:treat_options_keyword_as_hash])
      end

      # Lookup param type by infer
      #
      # @note module_function: defines #lookup_param_type_by_infer (visibility: private)
      # @param [Hash<String, String>, nil] param_types_override map of parameter name to override type
      # @param [String] pname the parameter name string
      # @param [String] infer_name parameter name string or transformed version for inference
      # @param [String] fallback_type default type string when inference fails
      # @param [Boolean, nil] treat_options_keyword_as_hash whether to treat options keyword as Hash type
      # @return [String]
      def lookup_param_type_by_infer(param_types_override, pname, infer_name, fallback_type,
                                     treat_options_keyword_as_hash)
        override_param_type_for(pname, param_types_override) ||
          Infer.infer_param_type(infer_name, nil,
                                 fallback_type: fallback_type,
                                 treat_options_keyword_as_hash: treat_options_keyword_as_hash || false)
      end

      # Format param tag
      #
      # @note module_function: defines #format_param_tag (visibility: private)
      # @param [String] indent indentation string for the doc line
      # @param [String] name the parameter name
      # @param [String] type the parameter type string
      # @param [String] documentation optional documentation text appended to the tag
      # @param [Symbol, String] style param tag style (:type_name or :name_type)
      # @return [String]
      def format_param_tag(indent, name, type, documentation, style:)
        doc = documentation.to_s.strip
        type = type.to_s
        line = build_param_tag_base(indent, name, type, style)
        doc.empty? ? line : append_param_doc(line, doc, indent)
      end

      # Build param tag base string
      #
      # @note module_function: defines #build_param_tag_base (visibility: private)
      # @param [String] indent indentation string
      # @param [String] name parameter name
      # @param [String] type parameter type string
      # @param [String, Symbol] style tag style symbol
      # @return [String]
      def build_param_tag_base(indent, name, type, style)
        case style.to_s
        when 'name_type' then "#{indent}# @param #{name} [#{type}]"
        else "#{indent}# @param [#{type}] #{name}"
        end
      end

      # Append param doc text
      #
      # @note module_function: defines #append_param_doc (visibility: private)
      # @param [String] line existing param tag line
      # @param [String] doc documentation text
      # @param [String] indent indentation string
      # @return [String]
      def append_param_doc(line, doc, indent)
        parts = doc.split("\n")
        result = +"#{line} #{parts.first}"
        parts[1..]&.each { |l| result << "\n#{indent}#   #{l}" }
        result
      end

      # Append option lines
      #
      # @note module_function: defines #append_option_lines (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Parser::AST::Node] default default value node
      # @param [String] indent indentation string for the doc line
      # @param [String] pname the parameter name to look up
      # @param [String] fallback_type default type string when inference fails
      # @return [void]
      def append_option_lines(lines, default, indent, pname, fallback_type)
        hash_option_pairs(default).each do |pair|
          lines << build_option_line(pair, indent, pname, fallback_type)
        end
      end

      # Hash option pairs
      #
      # @note module_function: defines #hash_option_pairs (visibility: private)
      # @param [Parser::AST::Node] node AST node for the default value, expected to be :hash type
      # @return [Array<Parser::AST::Node>]
      def hash_option_pairs(node)
        return [] unless node&.type == :hash

        node.children.select { |child| child.is_a?(Parser::AST::Node) && child.type == :pair }
      end

      # Build option line
      #
      # @note module_function: defines #build_option_line (visibility: private)
      # @param [Parser::AST::Node] pair AST pair node containing key and value
      # @param [String] indent indentation string for the doc line
      # @param [String] pname the parent parameter name for @option scope
      # @param [String] fallback_type default type string when inference fails
      # @return [String]
      def build_option_line(pair, indent, pname, fallback_type)
        key_node, value_node = pair.children
        option_key = option_key_name(key_node)
        option_type = Infer::Literals.type_from_literal(value_node, fallback_type: fallback_type)
        option_default = node_default_literal(value_node)

        line = "#{indent}# @option #{pname} [#{option_type}] :#{option_key}"
        line += " (#{option_default})" if option_default
        line += ' Description of this option.'
        line
      end

      # Option key name
      #
      # @note module_function: defines #option_key_name (visibility: private)
      # @param [Parser::AST::Node] key_node AST node for the hash key (:sym or :str type)
      # @return [String]
      def option_key_name(key_node)
        case key_node&.type
        when :sym, :str
          key_node.children.first.to_s
        else
          expression = key_node&.loc&.expression
          expression&.source.to_s.sub(/\A:/, '')
        end
      end

      # Node default literal
      #
      # @note module_function: defines #node_default_literal (visibility: private)
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @return [String, nil]
      def node_default_literal(node)
        expression = node&.loc&.expression
        expression&.source
      end

      # Override param type for
      #
      # @note module_function: defines #override_param_type_for (visibility: private)
      # @param [String] pname the parameter name to look up
      # @param [Hash<Object, String>, nil] override_map hash map of parameter name to override type
      # @return [String, nil]
      def override_param_type_for(pname, override_map)
        return nil unless override_map

        key = pname.to_s
        override_map[key] || override_map[:"#{key}"] || override_map["#{key}:"] || override_map[:"#{key}:"]
      end

      # Extract param description
      #
      # @note module_function: defines #extract_param_description (visibility: private)
      # @param [String] line a `@param` tag line
      # @return [String, nil]
      def extract_param_description(line)
        after = param_rest_after_type(line)
        return nil unless after

        parts = after.split(/\s+/, 2)
        parts[1] if parts.length > 1 && !parts[1].empty?
      end

      # Extract everything after the type bracket in a @param line.
      #
      # @note module_function: defines #param_rest_after_type (visibility: private)
      # @param [String] line a @param doc line
      # @return [String?] the text after the closing `]`, or nil
      def param_rest_after_type(line)
        content = line.sub(/^\s*#\s*/, '')
        if (m = content.match(/@param\s+(\S+\s+)?\[/))
          brace_end = m.end(0) #: Integer
          rest = content[(brace_end - 1)..] #: String
          type_end = find_matching_close_bracket(rest)
          return rest[(type_end + 1)..]&.strip if type_end
        end
        nil
      end
      ARG_DEFAULT_NAMES = { restarg: 'args', kwrestarg: 'kwargs', blockarg: 'block' }.freeze

      # Param name from arg
      #
      # @note module_function: defines #param_name_from_arg (visibility: private)
      # @param [Parser::AST::Node] arg_node AST node for the block argument (&block)
      # @return [String, nil]
      def param_name_from_arg(arg_node)
        return nil if arg_node.type == :forward_arg

        (arg_node.children.first || ARG_DEFAULT_NAMES[arg_node.type] || '').to_s
      end

      # Extract param name from param line
      #
      # @note module_function: defines #extract_param_name_from_param_line (visibility: private)
      # @param [String] line a `@param` doc line
      # @return [String, nil] the parameter name or nil
      def extract_param_name_from_param_line(line)
        content = line.sub(/^\s*#\s*/, '')
        if (m = content.match(/@param\s+(\S+)\s+\[/))
          return m[1]
        elsif (m = content.match(/@param\s+\[/))
          name_end = m.end(0) #: Integer
          rest = content[(name_end - 1)..] #: String
          type_end = find_matching_close_bracket(rest)
          return name_after_type_bracket(rest, type_end) if type_end
        end

        nil
      end

      # Extract name after type bracket
      #
      # @note module_function: defines #name_after_type_bracket (visibility: private)
      # @param [String] rest tag content after bracket
      # @param [Integer] type_end closing bracket position
      # @return [String?]
      def name_after_type_bracket(rest, type_end)
        rest[(type_end + 1)..].to_s.strip.split(/\s+/).first
      end

      # Extract param type from param line
      #
      # @note module_function: defines #extract_param_type_from_param_line (visibility: private)
      # @param [String] line a `@param` tag line
      # @return [String, nil]
      def extract_param_type_from_param_line(line)
        content = line.sub(/^\s*#\s*/, '')
        if (m = content.match(/@param\s+(\S+\s+)?\[/))
          name_end = m.end(0) #: Integer
          rest = content[(name_end - 1)..] #: String
          type_end = find_matching_close_bracket(rest)
          return rest[1...type_end] if type_end
        end
        nil
      end

      # Find matching close bracket
      #
      # @note module_function: defines #find_matching_close_bracket (visibility: private)
      # @param [String] str string to scan
      # @return [Integer, nil]
      def find_matching_close_bracket(str)
        depth = 0
        str.each_char.with_index do |c, i|
          case c
          when '[' then depth += 1
          when ']'
            depth -= 1
            return i if depth.zero?
          end
        end
        nil
      end

      # Collect missing raises
      #
      # @note module_function: defines #collect_missing_raises! (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def collect_missing_raises!(lines, reasons, **ctx)
        return unless ctx[:config].emit_raise_tags?

        inferred = Docscribe::Infer.infer_raises_from_node(ctx[:node])
        existing = ctx[:info][:raise_types] || {}
        missing = inferred.reject { |rt| existing[rt] }

        missing.each do |rt|
          lines << "#{ctx[:indent]}# @raise [#{rt}]\n"
          reasons << { type: :missing_raise, message: "missing @raise [#{rt}]", extra: { raise_type: rt } }
        end
      end

      # Collect missing return
      #
      # @note module_function: defines #collect_missing_return! (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def collect_missing_return!(lines, reasons, **ctx)
        return unless ctx[:config].emit_return_tag?(ctx[:scope], ctx[:visibility])

        if !ctx[:info][:has_return]
          record_missing_return(lines, reasons, ctx)
        elsif invalid_yard_return?(ctx)
          record_invalid_return(lines, reasons, ctx)
        elsif return_type_changed?(ctx)
          record_updated_return(lines, reasons, ctx)
        elsif should_validate_return?(ctx) && mismatched_return?(ctx) # rubocop:disable Lint/DuplicateBranch
          record_updated_return(lines, reasons, ctx)
        end
      end

      # Whether YARD return type has invalid syntax.
      #
      # @note module_function: defines #invalid_yard_return? (visibility: private)
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def invalid_yard_return?(ctx)
        yard = ctx[:info][:return_type]
        return false unless yard

        invalid_yard_type?(yard)
      end

      # Record invalid return type.
      #
      # @note module_function: defines #record_invalid_return (visibility: private)
      # @param [Array<String>] lines
      # @param [Array<Hash<Symbol, Object>>] reasons
      # @param [Hash<Symbol, Object>] ctx
      # @return [void]
      def record_invalid_return(lines, reasons, ctx)
        yard = ctx[:info][:return_type]
        lines << "#{ctx[:indent]}# @return [#{ctx[:normal_type]}]\n"
        reasons << {
          type: :invalid_type,
          message: "invalid YARD type [#{yard}] for @return, expected [#{ctx[:normal_type]}]",
          source: 'syntax'
        }
      end

      # Whether return validation should run via inferred types.
      #
      # @note module_function: defines #should_validate_return? (visibility: private)
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def should_validate_return?(ctx)
        ctx[:config].respond_to?(:validate_types?) && ctx[:config].validate_types?
      end

      # Whether YARD return mismatches expected inferred/external type.
      #
      # Silences when expected is fallback (uncertain).
      #
      # @note module_function: defines #mismatched_return? (visibility: private)
      # @param [Hash<Symbol, Object>] ctx
      # @return [Boolean]
      def mismatched_return?(ctx)
        yard, expected, fallback = mismatched_return_types(ctx)
        return false unless yard && expected
        return false if expected_suppressed?(expected, fallback)

        method_name = extract_method_name(ctx)
        return false if yard_compatible?(yard, expected, fallback, method_name: method_name)
        return false if types_normalized_equal?(yard, expected)

        true
      end

      # Extract method name for void compatibility dynamic check.
      #
      # @note module_function: defines #extract_method_name (visibility: private)
      # @param [Hash<Symbol, Object>] ctx context hash with insertion or node
      # @raise [StandardError]
      # @return [Symbol, nil]
      # @return [nil] if StandardError
      def extract_method_name(ctx)
        insertion = ctx[:insertion]
        node = insertion&.node || ctx[:node]
        return nil unless node

        SourceHelpers.node_name(node)
      rescue StandardError
        nil
      end

      # Extract yard/expected/fallback triple for return mismatch check.
      #
      # @note module_function: defines #mismatched_return_types (visibility: private)
      # @param [Hash<Symbol, Object>] ctx
      # @return [(String?, String?, String)]
      def mismatched_return_types(ctx)
        [ctx[:info][:return_type], ctx[:normal_type], ctx[:config].fallback_type]
      end

      # Whether expected type is suppressed as fallback.
      #
      # @note module_function: defines #expected_suppressed? (visibility: private)
      # @param [String?] expected
      # @param [String] fallback
      # @return [Boolean]
      def expected_suppressed?(expected, fallback)
        expected == fallback || fallback_union?(expected, fallback)
      end

      # Whether yard type is compatible with expected via void/union/generic.
      #
      # @note module_function: defines #yard_compatible? (visibility: private)
      # @param [String?] yard
      # @param [String?] expected
      # @param [String] fallback
      # @param [String, Symbol, nil] method_name method name for void compatibility
      # @return [Boolean]
      def yard_compatible?(yard, expected, fallback, method_name: nil)
        void_compatible?(yard, expected, fallback, method_name: method_name) ||
          yard_in_expected_union?(yard, expected) ||
          generic_compatible?(yard, expected, method_name: method_name)
      end

      # Whether types are equal after normalization (including optional "?").
      #
      # @note module_function: defines #types_normalized_equal? (visibility: private)
      # @param [String?] yard
      # @param [String?] expected
      # @return [Boolean]
      def types_normalized_equal?(yard, expected)
        normalized_equal?(yard, expected) || optional_normalized_equal?(yard, expected)
      end

      # Whether normalized types are equal.
      #
      # @note module_function: defines #normalized_equal? (visibility: private)
      # @param [String?] yard
      # @param [String?] expected
      # @return [Boolean]
      def normalized_equal?(yard, expected)
        normalize_type(yard) == normalize_type(expected)
      end

      # Whether optional-normalized types are equal.
      #
      # @note module_function: defines #optional_normalized_equal? (visibility: private)
      # @param [String?] yard
      # @param [String?] expected
      # @return [Boolean]
      def optional_normalized_equal?(yard, expected)
        normalize_type(yard).delete_suffix('?') == normalize_type(expected).delete_suffix('?')
      end

      # Delegates to GenericCompatibility service (dynamic, map-dispatched, no hardcodes).
      #
      # @note module_function: defines #generic_compatible? (visibility: private)
      # @param [String] yard
      # @param [String] expected
      # @param [String, Symbol, nil] method_name method name for void compatibility threading
      # @return [Boolean]
      def generic_compatible?(yard, expected, method_name: nil)
        Docscribe::Validator::GenericCompatibility.compatible?(yard, expected, fallback_type: 'Object', method_name: method_name)
      end

      # Whether yard type is included in expected union (e.g. Boolean in Object, Boolean).
      #
      # @note module_function: defines #yard_in_expected_union? (visibility: private)
      # @param [String] yard
      # @param [String] expected
      # @return [Boolean]
      def yard_in_expected_union?(yard, expected)
        normalized_yard = normalize_type(yard)
        expected.split(',').any? { |part| normalize_type(part) == normalized_yard }
      end

      # Whether void YARD type is compatible with fallback union or initialize/setup dynamic.
      #
      # @note module_function: defines #void_compatible? (visibility: private)
      # @param [String, nil] yard
      # @param [String, nil] expected
      # @param [String] fallback
      # @param [String, Symbol, nil] method_name method name for dynamic check
      # @return [Boolean]
      def void_compatible?(yard, expected, fallback, method_name: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/AbcSize
        return false unless normalize_type(yard) == 'void'

        return true if fallback_union?(expected, fallback) ||
                       %w[nil void].include?(normalize_type(expected))

        if method_name.to_s =~ /initialize|setup/
          norm = normalize_type(expected).delete_suffix('?').strip
          return true if norm == 'Hash' || norm.start_with?('Hash<') || norm.start_with?('Hash[')
          return true if %w[self Boolean].include?(norm)
        end

        if method_name.to_s.end_with?('?')
          norm = normalize_type(expected).delete_suffix('?').strip
          return true if norm == 'Boolean'
        end

        false
      end

      # Whether a type string is a union of only fallback types (with optional `?`).
      #
      # @note module_function: defines #fallback_union? (visibility: private)
      # @param [String, nil] type_str
      # @param [String] fallback
      # @return [Boolean]
      def fallback_union?(type_str, fallback)
        return false if type_str.nil? || type_str.strip.empty?

        fallback_norm = normalize_type(fallback)
        parts = type_str.to_s.split(',').map { |p| normalize_type(p.strip.delete_suffix('?').strip) }
        parts.all? { |p| p == fallback_norm || p.empty? }
      end

      # Normalize type string for comparison (unify RBS/YARD syntax).
      #
      # @note module_function: defines #normalize_type (visibility: private)
      # @param [String, nil] type_str
      # @return [String]
      def normalize_type(type_str)
        s = type_str.to_s
        s = s.sub(/#.*\z/m, '').strip unless s.lstrip.start_with?('#')
        s.strip.squeeze(' ').gsub('[', '<').gsub(']', '>').gsub(/\buntyped\b/, 'Object').gsub(/\bFALLBACK_TYPE\b/, 'Object')
      end

      # Record missing return
      #
      # @note module_function: defines #record_missing_return (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with normal_type and indent
      # @return [void]
      def record_missing_return(lines, reasons, ctx)
        lines << "#{ctx[:indent]}# @return [#{ctx[:normal_type]}]\n"
        reasons << { type: :missing_return, message: 'missing @return' }
      end

      # Record updated return
      #
      # @note module_function: defines #record_updated_return (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with normal_type and info
      # @return [void]
      def record_updated_return(lines, reasons, ctx)
        lines << "#{ctx[:indent]}# @return [#{ctx[:normal_type]}]\n" unless ctx[:strategy] == :safe
        reasons << { type: :updated_return,
                     message: "updated @return from #{ctx[:info][:return_type]} to #{ctx[:normal_type]}",
                     source: ctx[:external_sig] ? 'rbs' : 'infer' }
      end

      # Return type changed
      #
      # @note module_function: defines #return_type_changed? (visibility: private)
      # @param [Hash<Symbol, Object>] ctx merged context hash with external_sig, info, and normal_type
      # @return [Boolean]
      def return_type_changed?(ctx)
        ctx[:external_sig] && ctx[:info][:return_type] && ctx[:info][:return_type] != ctx[:normal_type]
      end

      # Collect missing rescue returns
      #
      # @note module_function: defines #collect_missing_rescue_returns! (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def collect_missing_rescue_returns!(lines, reasons, **ctx)
        return unless ctx[:config].emit_rescue_conditional_returns?
        return if ctx[:info][:has_return]

        ctx[:rescue_specs].each do |exceptions, rtype|
          next unless informative_rescue_type?(rtype)

          lines << "#{ctx[:indent]}# @return [#{rtype}] if #{exceptions.join(', ')}\n"
          reasons << {
            type: :missing_return,
            message: "missing conditional @return for #{exceptions.join(', ')}"
          }
        end
      end

      # Collect missing plugin tags
      #
      # @note module_function: defines #collect_missing_plugin_tags! (visibility: private)
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def collect_missing_plugin_tags!(lines, reasons, **ctx)
        plugin_tags = Docscribe::Plugin.run_tag_plugins(build_plugin_context(ctx[:insertion],
                                                                             normal_type: ctx[:normal_type]))
        plugin_tags.concat(Array(ctx[:override_tags])) if ctx[:override_tags]

        plugin_tags.each { |tag| record_plugin_tag(tag, lines, reasons, ctx) }
      end

      # Record plugin tag
      #
      # @note module_function: defines #record_plugin_tag (visibility: private)
      # @param [Docscribe::Plugin::Tag] tag plugin tag object to render and record
      # @param [Array<String>] lines array of output doc lines being accumulated
      # @param [Array<Hash<Symbol, Object>>] reasons array of reason hashes for --explain output
      # @param [Hash<Symbol, Object>] ctx merged context hash with info and indent
      # @return [void]
      def record_plugin_tag(tag, lines, reasons, ctx)
        return if ctx[:info][:plugin_tags]&.[](tag.name)

        rendered = render_plugin_tags([tag], ctx[:indent]).first
        lines << "#{rendered}\n"
        reasons << { type: :missing_plugin_tag, message: "missing @#{tag.name}" }
      end

      # Debug warn
      #
      # @note module_function: defines #debug_warn (visibility: private)
      # @param [StandardError] error the error that occurred
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the method insertion being processed
      # @param [String] name the method name
      # @param [String] phase the processing phase
      # @return [void]
      def debug_warn(error, insertion:, name:, phase:)
        return unless debug?

        where = build_debug_location(insertion, name)
        warn "Docscribe DEBUG: #{phase} failed at #{where}: #{error.class}: #{error.message}"
      end

      # Build debug location
      #
      # @note module_function: defines #build_debug_location (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [String] name the method name string
      # @return [String]
      def build_debug_location(insertion, name)
        return name.to_s unless insertion

        expr = insertion.node.loc.expression
        buf = expr.source_buffer.name
        sym = insertion.scope == :class ? '.' : '#'
        ctr = insertion.container || 'Object'
        +"#{buf}:#{expr.line} #{ctr}#{sym}#{name}"
      end

      # Debug
      #
      # @note module_function: defines #debug? (visibility: private)
      # @return [Boolean]
      def debug?
        ENV['DOCSCRIBE_DEBUG'] == '1'
      end

      # Build plugin context
      #
      # @note module_function: defines #build_plugin_context (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [String] normal_type resolved return type
      # @return [Docscribe::Plugin::Context]
      def build_plugin_context(insertion, normal_type:)
        node = insertion.node
        source = safe_node_source(node)
        new_plugin_context(insertion, node, source, normal_type)
      end

      # New plugin context
      #
      # @note module_function: defines #new_plugin_context (visibility: private)
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion object
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @param [String] source method source text
      # @param [String] normal_type resolved return type
      # @return [Docscribe::Plugin::Context]
      def new_plugin_context(insertion, node, source, normal_type)
        Docscribe::Plugin::Context.new(
          node: node,
          container: insertion.container,
          scope: insertion.scope,
          visibility: insertion.visibility,
          method_name: SourceHelpers.node_name(node), #: Symbol
          inferred_params: {},
          inferred_return: normal_type,
          source: source
        )
      end

      # Safe node source
      #
      # @note module_function: defines #safe_node_source (visibility: private)
      # @param [Parser::AST::Node] node AST node whose source text to extract
      # @raise [StandardError]
      # @return [String]
      # @return [String] if StandardError
      def safe_node_source(node)
        node.loc.expression.source
      rescue StandardError
        ''
      end

      # Render plugin tags
      #
      # @note module_function: defines #render_plugin_tags (visibility: private)
      # @param [Array<Docscribe::Plugin::Tag>] tags plugin tag objects
      # @param [String] indent indentation string for the doc line
      # @return [Array<String>]
      def render_plugin_tags(tags, indent)
        tags.map do |tag|
          type_part = tag.types&.any? ? " [#{tag.types.join(', ')}]" : ''
          text_part = tag.text ? " #{tag.text}" : ''
          "#{indent}# @#{tag.name}#{type_part}#{text_part}"
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'ast'
require 'parser/deprecation'
require 'parser/source/buffer'
require 'parser/source/range'
require 'parser/source/tree_rewriter'

require 'docscribe/config'
require 'docscribe/parsing'

require 'docscribe/inline_rewriter/source_helpers'
require 'docscribe/inline_rewriter/doc_builder'
require 'docscribe/inline_rewriter/collector'
require 'docscribe/inline_rewriter/doc_block'

module Docscribe
  # Raised when source cannot be parsed before rewriting.
  class ParseError < StandardError; end

  # Rewrite Ruby source to insert or update inline YARD-style documentation.
  #
  # Supported strategies:
  # - `:safe`
  #   - insert missing docs
  #   - merge into existing doc-like blocks
  #   - normalize configured sortable tags
  #   - preserve existing prose and directives where possible
  # - `:aggressive`
  #   - replace existing doc blocks with freshly generated docs
  #
  # Compatibility note:
  # - `merge: true` maps to `strategy: :safe`
  # - `rewrite: true` maps to `strategy: :aggressive`
  module InlineRewriter
    class << self
      # Insert comments
      #
      # @param [String] code Ruby source
      # @param [Symbol?] strategy :safe or :aggressive
      # @param [Boolean?] rewrite compatibility alias for aggressive strategy
      # @param [Boolean?] merge compatibility alias for safe strategy
      # @param [Hash] options additional keyword arguments forwarded to rewrite_with_report
      # @return [String]
      def insert_comments(code, strategy: nil, rewrite: nil, merge: nil, **options)
        strategy = normalize_strategy(strategy: strategy, rewrite: rewrite, merge: merge)

        rewrite_with_report(code, strategy: strategy, **options)[:output]
      end

      # Rewrite with report
      #
      # @param [String] code Ruby source
      # @param [Symbol?] strategy :safe or :aggressive
      # @param [Boolean?] rewrite compatibility alias for aggressive strategy
      # @param [Boolean?] merge compatibility alias for safe strategy
      # @param [Hash] options additional keyword arguments forwarded to downstream helpers
      # @return [Hash<Symbol, String, Array<Docscribe::InlineRewriter::changeRecord>>]
      def rewrite_with_report(code, strategy: nil, rewrite: nil, merge: nil, **options)
        strategy = normalize_strategy(strategy: strategy, rewrite: rewrite, merge: merge)
        validate_strategy!(strategy)
        parsed = setup_rewrite_env(code, options)
        pipeline = build_rewrite_pipeline(parsed[:buffer], parsed[:ast])
        dispatch_rewrite_insertions(pipeline, parsed[:buffer],
                                    config: parsed[:config], signature_provider: parsed[:signature_provider],
                                    core_rbs_provider: parsed[:core_rbs_provider], strategy: strategy,
                                    file: parsed[:file])
        { output: pipeline[:rewriter].process, changes: pipeline[:changes] }
      end

      # Build rewrite pipeline
      #
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @param [Parser::AST::Node] ast the parsed AST of the source code
      # @return [Docscribe::InlineRewriter::pipeline]
      def build_rewrite_pipeline(buffer, ast)
        all = collect_insertions(buffer, ast)
        method_overrides_by_pos = {} #: Hash[Integer, untyped]
        all = deduplicate_insertions(all, method_overrides_by_pos: method_overrides_by_pos)
        rewriter = Parser::Source::TreeRewriter.new(buffer) # steep:ignore
        merge_inserts = Hash.new { |h, k| h[k] = [] } #: Hash[Integer, untyped]
        changes = [] #: Array[untyped]

        { all: all, method_overrides_by_pos: method_overrides_by_pos, rewriter: rewriter,
          merge_inserts: merge_inserts, changes: changes }
      end

      # Dispatch rewrite insertions
      #
      # @param [Docscribe::InlineRewriter::pipeline] pipeline the pipeline hash with rewriter, insertions, and tracking state
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @param [Hash] options additional kwargs (config, signature_provider, core_rbs_provider, strategy, file)
      # @return [void]
      def dispatch_rewrite_insertions(pipeline, buffer, **options)
        pipeline[:all].sort_by { |(kind, ins)| plugin_insertion_pos(kind, ins) }
                      .reverse_each do |kind, ins|
          dispatch_single_insertion(kind, ins, pipeline, buffer, **options)
        end

        apply_merge_inserts!(rewriter: pipeline[:rewriter], buffer: buffer, merge_inserts: pipeline[:merge_inserts])
      end

      # Dispatch a single insertion, isolating per-method failures.
      #
      # A crash while documenting one method (e.g., unexpected AST shape)
      # must not discard warnings for the rest of the file: the error is
      # reported to stderr and the remaining insertions still apply.
      #
      # @param [Symbol] kind insertion kind (:method, :attr, :plugin)
      # @param [Object] ins the insertion object
      # @param [Docscribe::InlineRewriter::pipeline] pipeline the pipeline hash with rewriter, insertions, and tracking state
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @param [Hash] options additional kwargs (config, signature_provider, core_rbs_provider, strategy, file)
      # @raise [StandardError]
      # @return [void]
      def dispatch_single_insertion(kind, ins, pipeline, buffer, **options)
        method_name = :"dispatch_#{kind}_insertion"
        return unless respond_to?(method_name, true)

        send(method_name, ins, pipeline, buffer, **options)
      rescue StandardError => e
        warn_insertion_error(kind, ins, options[:file], e)
      end

      # Report a skipped insertion to stderr without interrupting the rewrite.
      #
      # @param [Symbol] kind insertion kind (:method, :attr, :plugin)
      # @param [Object] ins the insertion object
      # @param [String, nil] file the file being rewritten
      # @param [StandardError] error the rescued error
      # @return [void]
      def warn_insertion_error(kind, ins, file, error)
        warn "Docscribe: skipping #{insertion_label(kind, ins)} in #{file}: #{error.class}: #{error.message}"
      end

      # Human-readable label for an insertion used in skip warnings.
      #
      # @param [Symbol] kind insertion kind (:method, :attr, :plugin)
      # @param [Object] ins the insertion object
      # @return [String] label like "method foo at line 12"
      def insertion_label(kind, ins)
        node = insertion_node(ins)
        name = node ? SourceHelpers.node_name(node) : nil
        line = node_line(node)
        label = name ? "#{kind} #{name}" : kind.to_s
        line ? "#{label} at line #{line}" : label
      end

      # Extract the AST node from an insertion when available.
      #
      # @param [Object] ins the insertion object
      # @return [Parser::AST::Node, nil] the node or nil
      def insertion_node(ins)
        ins.respond_to?(:node) ? ins.node : nil
      end

      # Source line of a node expression when available.
      #
      # @param [Parser::AST::Node, nil] node an AST node
      # @return [Integer, nil] 1-based line number or nil
      def node_line(node)
        loc = node&.loc
        expr = loc&.expression
        expr&.line
      end

      # Dispatch method insertion
      #
      # @param [Docscribe::InlineRewriter::Collector::Insertion] ins the attribute insertion object
      # @param [Docscribe::InlineRewriter::pipeline] pipeline the pipeline hash with rewriter, insertions, and tracking state
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Hash] options the full keyword options hash
      # @return [void]
      def dispatch_method_insertion(ins, pipeline, buffer, **options)
        pos = plugin_insertion_pos(:method, ins)
        method_override = pipeline[:method_overrides_by_pos][pos]

        apply_method_insertion!(
          rewriter: pipeline[:rewriter], buffer: buffer, insertion: ins,
          config: options[:config], signature_provider: options[:signature_provider],
          core_rbs_provider: options[:core_rbs_provider], strategy: options[:strategy],
          changes: pipeline[:changes], file: options[:file],
          method_override: method_override
        )
      end

      # Dispatch attr insertion
      #
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [Docscribe::InlineRewriter::pipeline] pipeline the pipeline hash with rewriter, insertions, and tracking state
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Hash] options the full keyword options hash
      # @return [void]
      def dispatch_attr_insertion(ins, pipeline, buffer, **options)
        apply_attr_insertion!(
          rewriter: pipeline[:rewriter], buffer: buffer, insertion: ins,
          config: options[:config], signature_provider: options[:signature_provider],
          strategy: options[:strategy], merge_inserts: pipeline[:merge_inserts]
        )
      end

      # Dispatch plugin insertion
      #
      # @param [Docscribe::InlineRewriter::pluginInsertion] ins the attribute insertion object
      # @param [Docscribe::InlineRewriter::pipeline] pipeline the pipeline hash with rewriter, insertions, and tracking state
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Hash] options the full keyword options hash
      # @return [void]
      def dispatch_plugin_insertion(ins, pipeline, buffer, **options)
        apply_plugin_insertion!(
          rewriter: pipeline[:rewriter], buffer: buffer, insertion: ins,
          strategy: options[:strategy], config: options[:config]
        )
      end

      private

      # Setup rewrite env
      #
      # @private
      # @param [String] code the Ruby source code string to parse and rewrite
      # @param [Hash<Symbol, Object>] options hash containing :config, :file, and :core_rbs_provider
      # @raise [Docscribe::ParseError]
      # @return [Hash<Symbol, Docscribe::Config, String, Parser::Source::Buffer, Parser::AST::Node, Docscribe::Types::ProviderChain, nil, Docscribe::Types::RBS::Provider, nil>] rewrite environment with keys
      #   :config, :file, :buffer, :ast, :core_rbs_provider
      def setup_rewrite_env(code, options)
        config = options[:config] || Docscribe::Config.load
        file = (options[:file] || '(inline)').to_s
        core_rbs_provider = options[:core_rbs_provider]
        buffer = Parser::Source::Buffer.new(file, source: code)
        ast = Docscribe::Parsing.parse_buffer(buffer)
        raise Docscribe::ParseError, "Failed to parse #{file}" unless ast

        { config: config, file: file, buffer: buffer, ast: ast,
          signature_provider: build_signature_provider(config, code, file),
          core_rbs_provider: load_core_rbs_provider(config, core_rbs_provider) }
      end

      # Load core rbs provider
      #
      # @private
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::Types::RBS::Provider, nil] core_rbs_provider optional externally-provided core RBS provider
      # @raise [StandardError]
      # @return [Docscribe::Types::RBS::Provider, nil]
      # @return [nil] if StandardError
      def load_core_rbs_provider(config, core_rbs_provider)
        core_rbs_provider || (config.respond_to?(:core_rbs_provider) ? config.core_rbs_provider : nil)
      rescue StandardError => e
        warn "Docscribe: failed to load core RBS provider: #{e.message}" if ENV.fetch('DOCSCRIBE_DEBUG', false)
        nil
      end

      # Collect insertions
      #
      # @private
      # @param [Parser::Source::Buffer] buffer the source buffer to collect insertions from
      # @param [Parser::AST::Node] ast the parsed AST to traverse for collection
      # @return [Array<Docscribe::InlineRewriter::insertionPair>]
      def collect_insertions(buffer, ast)
        collector = Docscribe::InlineRewriter::Collector.new(buffer)
        collector.process(ast)
        plugin_insertions = Docscribe::Plugin.run_collector_plugins(ast, buffer)
        method_insertions = collector.insertions
        attr_insertions = collector.respond_to?(:attr_insertions) ? collector.attr_insertions : [] #: Array[untyped]
        method_insertions.map { |i| [:method, i] } +
          attr_insertions.map { |i| [:attr, i] } +
          plugin_insertions.map { |i| [:plugin, i] }
      end

      # Deduplicate insertions
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] insertions insertions to deduplicate
      # @param [Hash<Integer, Docscribe::InlineRewriter::methodOverride>?] method_overrides_by_pos method-level overrides keyed
      #   by insertion position
      # @return [Array<Docscribe::InlineRewriter::insertionPair>]
      def deduplicate_insertions(insertions, method_overrides_by_pos: nil)
        group_by_position(insertions).each_with_object([]) do |(pos, items), result|
          process_dedup_group(pos, items, result, method_overrides_by_pos)
        end
      end

      # Process dedup group
      #
      # @private
      # @param [Integer] pos the source begin_pos for the group
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] items grouped items to process
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] result accumulated result array
      # @param [Hash<Integer, Docscribe::InlineRewriter::methodOverride>, nil] method_overrides_by_pos hash mapping position to method
      #   override data
      # @return [void]
      def process_dedup_group(pos, items, result, method_overrides_by_pos)
        plugin_items = items.select { |pair| pair.first == :plugin }
        return result.concat(items) if plugin_items.empty?

        method_items = items.select { |pair| pair.first == :method }
        override_items = find_override_items(plugin_items)
        if override_items.any? && method_items.any?
          handle_override_case(result, items, override_items, method_overrides_by_pos, pos)
        else
          result.concat(deduplicate_items(items, plugin_items, pos, method_items))
        end
      end

      # Group by position
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] insertions insertions to group
      # @return [Hash<Integer, Array<Docscribe::InlineRewriter::insertionPair>>]
      def group_by_position(insertions)
        groups = {} #: Hash[Integer, untyped]
        insertions.each do |kind, ins|
          pos = plugin_insertion_pos(kind, ins)
          (groups[pos] ||= []) << [kind, ins]
        end
        groups
      end

      # Find override items
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] plugin_items plugin items to check
      # @return [Array<Docscribe::InlineRewriter::insertionPair>]
      def find_override_items(plugin_items)
        plugin_items.select do |_k, ins|
          ins.is_a?(Hash) && ins[:method_override].is_a?(Hash)
        end
      end

      # Handle override case
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] result accumulated result array
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] items all items in group
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] override_items override plugin items
      # @param [Hash<Integer, Docscribe::InlineRewriter::methodOverride>, nil] method_overrides_by_pos hash mapping position to
      #   method override data
      # @param [Integer] pos the source position of the conflict
      # @return [void]
      def handle_override_case(result, items, override_items, method_overrides_by_pos, pos)
        if method_overrides_by_pos
          winning_ins = pick_highest_priority_override_insertion(override_items, pos: pos)
          method_overrides_by_pos[pos] = winning_ins[:method_override] if winning_ins
        end

        items = items.reject { |k, ins| k == :plugin && ins.is_a?(Hash) && ins.key?(:method_override) }
        result.concat(items)
      end

      # Deduplicate items
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] items all items in group
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] plugin_items plugin items in group
      # @param [Integer] pos the source position of the conflict
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] _method_items method items in group
      # @return [Array<Docscribe::InlineRewriter::insertionPair>]
      def deduplicate_items(items, plugin_items, pos, _method_items)
        plugin_doc_items = plugin_items.select { |pair| plugin_doc_item?(pair) }

        if plugin_doc_items.any?
          deduplicate_plugin_doc_case(items, plugin_doc_items, pos)
        else
          items.reject { |pair| override_or_plugin_method?(pair) }
        end
      end

      # Plugin doc item
      #
      # @private
      # @param [Docscribe::InlineRewriter::insertionPair] pair insertion pair to check
      # @return [Boolean]
      def plugin_doc_item?(pair)
        _k, ins = pair
        ins.is_a?(Hash) && ins[:doc] && !ins[:doc].empty?
      end

      # Deduplicate plugin doc case
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] items all items in group
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] plugin_doc_items plugin doc items
      # @param [Integer] pos the source position of the conflict
      # @return [Array<Docscribe::InlineRewriter::insertionPair>]
      def deduplicate_plugin_doc_case(items, plugin_doc_items, pos)
        items = items.reject { |k, _| k == :method }
        items = items.reject { |pair| override_or_plugin_method?(pair) }

        max_prio = max_plugin_priority(plugin_doc_items)
        dropped = filter_lower_priority_plugins(items, max_prio)
        items = items.reject { |k, ins| dropped.include?([k, ins]) }

        warn_plugin_conflict!(dropped, plugin_doc_items, max_prio, pos) if Docscribe::Plugin.debug? && dropped.any?

        items
      end

      # Override or plugin method
      #
      # @private
      # @param [Docscribe::InlineRewriter::insertionPair] pair insertion pair to check
      # @return [Boolean]
      def override_or_plugin_method?(pair)
        k, ins = pair
        k == :plugin && ins.is_a?(Hash) && ins.key?(:method_override)
      end

      # Max plugin priority
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] plugin_items plugin items to scan
      # @return [Integer]
      def max_plugin_priority(plugin_items)
        plugin_items.map { |_k, ins| plugin_insertion_priority(ins) }.max || 0
      end

      # Filter lower priority plugins
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] items items to filter
      # @param [Integer] threshold minimum priority threshold
      # @return [Array<Docscribe::InlineRewriter::insertionPair>]
      def filter_lower_priority_plugins(items, threshold)
        items.select do |k, ins|
          k == :plugin && ins.is_a?(Hash) && ins[:doc] && plugin_insertion_priority(ins) < threshold
        end
      end

      # Warn plugin conflict
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] dropped dropped plugin items
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] plugin_items kept plugin items
      # @param [Integer] max_prio the maximum priority value
      # @param [Integer] pos the source position of the conflict
      # @return [void]
      def warn_plugin_conflict!(dropped, plugin_items, max_prio, pos)
        kept_labels = plugin_items.map { |_k, ins| plugin_insertion_label(ins) }.uniq
        dropped_labels = dropped.map { |_k, ins| plugin_insertion_label(ins) }.uniq
        loc = conflict_location_str(pos, plugin_items)
        warn "Docscribe: CollectorPlugin conflict at #{loc} — " \
             "#{dropped_labels.join(', ')} (pri=#{dropped.map { |_k, ins| plugin_insertion_priority(ins) }.max}) " \
             "dropped in favor of #{kept_labels.join(', ')} (pri=#{max_prio}). " \
             'Set explicit priority or adjust anchor_node to avoid collision.'
      end

      # Conflict location str
      #
      # @private
      # @param [Integer] pos the source position of the conflict
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] plugin_items plugin items for location
      # @return [String]
      def conflict_location_str(pos, plugin_items)
        line = plugin_insertion_line(plugin_items.first[1])
        "pos=#{pos}#{" line=#{line}" if line}"
      end

      # Pick highest priority override insertion
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] override_items override items to prioritize
      # @param [Integer] pos begin_pos (used only for debug output)
      # @return [Docscribe::InlineRewriter::pluginInsertion, nil] winning insertion hash (the one whose override will be applied)
      def pick_highest_priority_override_insertion(override_items, pos:)
        return nil if override_items.empty?

        max_prio = max_plugin_priority_for(override_items)
        winners  = override_items.select { |_k, ins| plugin_insertion_priority(ins) == max_prio }
        winners_sorted = sort_winners_by_order(winners)

        warn_override_conflict!(winners_sorted, max_prio, pos)

        winners_sorted.first[1]
      end

      # Max plugin priority for
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] override_items override items to evaluate
      # @return [Integer]
      def max_plugin_priority_for(override_items)
        override_items.map { |_k, ins| plugin_insertion_priority(ins) }.max || 0
      end

      # Sort winners by order
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] winners winning items to sort
      # @return [Array<Docscribe::InlineRewriter::insertionPair>]
      def sort_winners_by_order(winners)
        winners.sort_by do |_k, ins|
          order = ins.is_a?(Hash) ? ins[:__docscribe_plugin_order] : nil
          order || 0
        end
      end

      # Warn override conflict
      #
      # @private
      # @param [Array<Docscribe::InlineRewriter::insertionPair>] winners_sorted sorted winning items
      # @param [Integer] max_prio the maximum priority value
      # @param [Integer] pos the source position of the conflict
      # @return [void]
      def warn_override_conflict!(winners_sorted, max_prio, pos)
        return unless Docscribe::Plugin.debug?

        labels = winners_sorted.map { |_k, ins| plugin_insertion_label(ins) }.uniq
        return unless labels.size > 1

        line = plugin_insertion_line(winners_sorted.first[1])
        loc = +"pos=#{pos}"
        loc << " line=#{line}" if line
        warn "Docscribe: method_override conflict at #{loc} (priority=#{max_prio}): " \
             "#{labels.join(', ')} — using first by registration order."
      end

      # Plugin insertion priority
      #
      # @private
      # @param [Docscribe::InlineRewriter::pluginInsertion, Docscribe::InlineRewriter::Collector::Insertion, Docscribe::InlineRewriter::Collector::AttrInsertion] insertion the collected
      #   method insertion (plugin hash or collected insertion object)
      # @raise [StandardError]
      # @return [Integer]
      # @return [Integer] if StandardError
      def plugin_insertion_priority(insertion)
        return 0 unless insertion.is_a?(Hash)

        Integer(insertion[:__docscribe_priority] || 0)
      rescue StandardError
        0
      end

      # Plugin insertion label
      #
      # @private
      # @param [Docscribe::InlineRewriter::pluginInsertion, Docscribe::InlineRewriter::Collector::Insertion, Docscribe::InlineRewriter::Collector::AttrInsertion] insertion the collected
      #   method insertion (plugin hash or collected insertion object)
      # @raise [StandardError]
      # @return [String]
      # @return [String] if StandardError
      def plugin_insertion_label(insertion)
        return 'unknown' unless insertion.is_a?(Hash)

        label = insertion[:__docscribe_plugin_class].to_s
        label.empty? ? 'unknown' : label
      rescue StandardError
        'unknown'
      end

      # Plugin insertion line
      #
      # @private
      # @param [Docscribe::InlineRewriter::pluginInsertion, Docscribe::InlineRewriter::Collector::Insertion, Docscribe::InlineRewriter::Collector::AttrInsertion] insertion the collected
      #   method insertion (plugin hash or collected insertion object)
      # @raise [StandardError]
      # @return [Integer, nil]
      # @return [nil] if StandardError
      def plugin_insertion_line(insertion)
        return nil unless insertion.is_a?(Hash)

        anchor_node = insertion[:anchor_node]
        expression = anchor_node&.loc&.expression
        expression&.line
      rescue StandardError
        nil
      end

      # Plugin insertion pos
      #
      # @private
      # @param [Symbol] kind :method, :attr, or :plugin
      # @param [Docscribe::InlineRewriter::pluginInsertion] ins insertion to locate
      # @return [Integer]
      def plugin_insertion_pos(kind, ins)
        case kind
        when :plugin
          plugin_ins = ins #: Hash[Symbol, untyped]
          plugin_ins[:anchor_node].loc.expression.begin_pos
        else
          method_ins = ins #: Collector::Insertion | Collector::AttrInsertion
          method_ins.node.loc.expression.begin_pos
        end
      end

      # Apply plugin insertion
      #
      # @private
      # @param [Parser::Source::TreeRewriter] rewriter the TreeRewriter accumulating source transformations
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Docscribe::InlineRewriter::pluginInsertion] insertion { anchor_node:, doc: }
      # @param [Symbol] strategy :safe or :aggressive rewrite mode
      # @param [Docscribe::Config] config the active configuration
      # @return [void]
      def apply_plugin_insertion!(rewriter:, buffer:, insertion:, strategy:, config:)
        anchor_node, doc = insertion.values_at(:anchor_node, :doc)
        return unless anchor_node && doc && !doc.empty?

        indent = SourceHelpers.line_indent(anchor_node)
        doc = normalize_plugin_doc(doc, indent, config: config, anchor_node: anchor_node)
        bol_range = SourceHelpers.line_start_range(buffer, anchor_node)
        insert_plugin_doc(rewriter, buffer, bol_range, doc, strategy)
      end

      # Insert plugin doc
      #
      # @private
      # @param [Parser::Source::TreeRewriter] rewriter the TreeRewriter accumulating source transformations
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @param [Parser::Source::Range] bol_range the beginning-of-line range for the anchor node
      # @param [String] doc the normalized documentation string to insert
      # @param [Symbol] strategy :safe or :aggressive rewrite mode
      # @return [void]
      def insert_plugin_doc(rewriter, buffer, bol_range, doc, strategy)
        case strategy
        when :aggressive
          range = any_comment_block_removal_range(buffer, bol_range.begin_pos)
          rewriter.remove(range) if range
          rewriter.insert_before(bol_range, doc)
        when :safe
          return if SourceHelpers.already_has_doc_immediately_above?(buffer, bol_range.begin_pos)

          rewriter.insert_before(bol_range, doc)
        end
      end

      # Any comment block removal range
      #
      # @private
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Integer] bol_pos beginning-of-line position of anchor_node
      # @return [Parser::Source::Range, nil]
      def any_comment_block_removal_range(buffer, bol_pos)
        src   = buffer.source
        lines = src.lines
        i = nearest_comment_line_index(src, lines, bol_pos)
        return nil unless i

        start_idx = comment_block_start_index(lines, i)

        removable_start_idx = skip_preserved_lines(lines, start_idx, i)
        return nil if removable_start_idx > i

        start_pos = removable_start_idx.positive? ? (lines[0...removable_start_idx] || []).join.length : 0
        Parser::Source::Range.new(buffer, start_pos, bol_pos)
      end

      # Nearest comment line index
      #
      # @private
      # @param [String] src the full source string of the buffer
      # @param [Array<String>] lines array of source code lines
      # @param [Integer] bol_pos character position of the beginning of the anchor line
      # @return [Integer, nil]
      def nearest_comment_line_index(src, lines, bol_pos)
        def_line_idx = (src[0...bol_pos] || '').count("\n")
        i = def_line_idx - 1
        i -= 1 while i >= 0 && lines[i].strip.empty?
        return nil unless i >= 0 && lines[i] =~ /^\s*#/

        i
      end

      # Comment block start index
      #
      # @private
      # @param [Array<String>] lines array of source code lines
      # @param [Integer] def_line_idx the index in lines of the method definition (anchor) line
      # @return [Integer]
      def comment_block_start_index(lines, def_line_idx)
        start_idx = def_line_idx
        start_idx -= 1 while start_idx >= 0 && lines[start_idx] =~ /^\s*#/
        start_idx + 1
      end

      # Skip preserved lines
      #
      # @private
      # @param [Array<String>] lines array of source code lines
      # @param [Integer] start_idx index of the first line of the comment block
      # @param [Integer] def_line_idx the index in lines of the method definition (anchor) line
      # @return [Integer]
      def skip_preserved_lines(lines, start_idx, def_line_idx)
        idx = start_idx
        idx += 1 while idx <= def_line_idx && SourceHelpers.preserved_comment_line?(lines[idx])
        idx
      end

      # Normalize plugin doc
      #
      # @private
      # @param [String] doc Raw doc string returned by a CollectorPlugin insertion (`:doc`)
      # @param [String] indent Indentation to apply to every doc line
      # @param [Docscribe::Config] config Effective Docscribe config for this run
      # @param [Parser::AST::Node, nil] anchor_node AST node used as insertion anchor
      # @return [String] Normalized doc string ready to be inserted
      def normalize_plugin_doc(doc, indent, config:, anchor_node:)
        doc = normalize_plugin_doc_indent(doc, indent)
        doc = trim_trailing_blank_lines(doc)
        doc = prepend_default_message_if_no_prose(doc, anchor_node, indent, config) if anchor_node && %i[def defs].include?(anchor_node.type) && config.include_default_message?
        doc
      end

      # Trim trailing blank lines
      #
      # @private
      # @param [String] doc the documentation string to trim
      # @return [String]
      def trim_trailing_blank_lines(doc)
        lines = doc.lines
        lines.pop while lines.any? && lines.last.strip.empty?
        result = lines.join
        result.end_with?("\n") ? result : "#{result}\n"
      end

      # Prepend default message if no prose
      #
      # @private
      # @param [String] doc the plugin-generated documentation string
      # @param [Parser::AST::Node] anchor_node the AST node used as the insertion anchor
      # @param [String] indent whitespace indentation prefix derived from the anchor node
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @return [String]
      def prepend_default_message_if_no_prose(doc, anchor_node, indent, config)
        return doc if doc_has_prose?(doc)

        scope = anchor_node.type == :defs ? :class : :instance
        msg = config.default_message(scope, :public)
        "#{indent}# #{msg}\n#{indent}#\n" + doc
      end

      # Doc has prose
      #
      # @private
      # @param [String] doc the documentation string to inspect
      # @return [Boolean]
      def doc_has_prose?(doc)
        doc.lines.any? do |l|
          s = l.strip
          next false if s.empty? || s == '#'
          next false if s.start_with?('# @')
          next false if s.start_with?('# +')

          true
        end
      end

      # Normalize plugin doc indent
      #
      # @private
      # @param [String] doc raw doc string from plugin
      # @param [String] indent indentation prefix to apply
      # @return [String]
      def normalize_plugin_doc_indent(doc, indent)
        doc.lines.map do |line|
          stripped = line.lstrip
          stripped.match?(/\A\r?\n?\z/) ? line : "#{indent}#{stripped}"
        end.join
      end

      # Normalize strategy
      #
      # @private
      # @param [Symbol, nil] strategy :safe or :aggressive rewrite mode
      # @param [Boolean, nil] rewrite compatibility alias for aggressive strategy
      # @param [Boolean, nil] merge compatibility alias for safe strategy
      # @return [Symbol]
      def normalize_strategy(strategy:, rewrite:, merge:)
        return strategy if strategy
        return :aggressive if rewrite
        return :safe if merge

        :safe
      end

      # Validate strategy
      #
      # @private
      # @param [Symbol] strategy :safe or :aggressive rewrite mode
      # @raise [ArgumentError]
      # @return [void]
      def validate_strategy!(strategy)
        return if %i[safe aggressive].include?(strategy)

        raise ArgumentError, "Unknown strategy: #{strategy.inspect}"
      end

      # Apply method insertion
      #
      # @private
      # @param [Hash] options kwargs with insertion, config, rewriter, buffer, strategy, changes, file, doc params
      # @return [void]
      def apply_method_insertion!(**options)
        insertion = options[:insertion]
        config = options[:config]
        return unless method_insertion_allowed?(insertion, config)

        anchor_bol_range, = method_bol_ranges(options[:buffer], insertion)
        params = build_method_insertion_params(insertion, config, options[:signature_provider],
                                               options[:core_rbs_provider], options[:method_override])
        extract_existing_descriptions!(options[:buffer], insertion, params, options[:strategy], config)
        doc = DocBuilder.build(insertion, **params) # steep:ignore
        dispatch_method_insertion_by_strategy!(anchor_bol_range, options, params, doc)
      end

      # Dispatch method insertion by strategy
      #
      # @private
      # @param [Parser::Source::Range] anchor_bol_range the beginning-of-line range for the anchor node
      # @param [Hash<Symbol, Object>] options the full keyword options hash passed to apply_method_insertion!
      # @param [Hash<Symbol, Object>] params precomputed insertion parameters (types, overrides, config)
      # @param [String, nil] doc the generated documentation block string
      # @return [void]
      def dispatch_method_insertion_by_strategy!(anchor_bol_range, options, params, doc)
        base = { anchor_bol_range: anchor_bol_range, insertion: options[:insertion],
                 rewriter: options[:rewriter], buffer: options[:buffer],
                 changes: options[:changes], file: options[:file] }
        case options[:strategy]
        when :aggressive then apply_method_insertion_aggressive!(**base, doc: doc)
        when :safe then apply_method_insertion_safe!(**base, strategy: options[:strategy], **params)
        end
      end

      # Method insertion allowed
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @param [Docscribe::Config] config the active configuration
      # @return [Boolean] true if insertion should proceed
      def method_insertion_allowed?(insertion, config)
        name = SourceHelpers.node_name(insertion.node) #: Symbol
        config.process_method?(container: insertion.container, scope: insertion.scope,
                               visibility: insertion.visibility || :public, name: name)
      end

      # Extract existing descriptions
      #
      # @private
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @param [Hash<Symbol, Object>] params precomputed attribute insertion parameters
      # @param [Symbol] strategy :safe or :aggressive rewrite mode
      # @param [Docscribe::Config] config the active configuration
      # @return [void]
      def extract_existing_descriptions!(buffer, insertion, params, strategy, config)
        return unless strategy == :aggressive && config.keep_descriptions?

        parsed = DocBuilder.parse_existing_doc_tags(
          method_doc_comment_info(buffer, insertion)&.dig(:doc_lines) || []
        )
        merge_existing_descriptions!(params, parsed)
      end

      # Merge parsed descriptions into insertion params
      #
      # @private
      # @param [Hash<Symbol, Object>] params insertion params
      # @param [Hash<Symbol, Object>] parsed parsed tag info
      # @return [void]
      def merge_existing_descriptions!(params, parsed)
        params[:param_descriptions] = parsed[:param_descriptions] if parsed[:param_descriptions].any?
        params[:return_description] = parsed[:return_description] if parsed[:return_description] && !parsed[:return_description].start_with?('if ')
        params[:description] = parsed[:description] if parsed[:description].any?
      end

      # Build method insertion params
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @param [Docscribe::Config] config the active configuration
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider RBS signature provider
      # @param [Docscribe::Types::RBS::Provider, nil] core_rbs_provider optional externally-provided core RBS provider
      # @param [Docscribe::InlineRewriter::methodOverride, nil] method_override the raw override data
      # @return [Hash<Symbol, Object>]
      def build_method_insertion_params(insertion, config, signature_provider, core_rbs_provider, method_override)
        override = extract_method_override!(method_override)
        effective = build_effective_params(insertion, config: config, signature_provider: signature_provider,
                                                      core_rbs_provider: core_rbs_provider, override: override)
        { **effective, config: config, signature_provider: signature_provider,
                       core_rbs_provider: core_rbs_provider }
      end

      # Build effective params
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @param [Hash] options keyword options
      # @return [Hash<Symbol, Hash<String, String>, nil, String, nil, Array<Docscribe::Plugin::Tag>>]
      def build_effective_params(insertion, **options)
        external_sig = resolve_external_signature(insertion, options[:signature_provider])
        param_types = resolve_param_types(insertion, external_sig, options[:config])
        override = options[:override]

        param_types = (param_types || {}).merge(override[:param_types]) if override[:param_types]&.any?

        { param_types: param_types, return_type_override: override[:return_type], override_tags: override[:tags] }
      end

      # Resolve external signature
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider external RBS signature provider
      # @return [Docscribe::Types::MethodSignature, nil]
      def resolve_external_signature(insertion, signature_provider)
        node_name = SourceHelpers.node_name(insertion.node) #: Symbol
        param_count, param_names = extract_param_info(insertion)
        signature_provider&.signature_for(
          container: insertion.container,
          scope: insertion.scope,
          name: node_name,
          param_count: param_count,
          param_names: param_names
        )
      end

      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion
      # @return [(Integer?, Array<String>)]
      def extract_param_info(insertion)
        args = DocBuilder.extract_args_from_node(insertion.node)
        empty = [] #: Array[untyped]
        return [nil, empty] unless args

        [args.children.length, args.children.map { |a| a.children.first.to_s if a.respond_to?(:children) }.compact]
      end

      # Resolve param types
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @param [Docscribe::Types::MethodSignature, nil] external_sig the resolved signature from the signature provider
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @return [Hash<String, String>, nil]
      def resolve_param_types(insertion, external_sig, config)
        DocBuilder.build_param_types_from_node(insertion.node, external_sig: external_sig, config: config)
      end

      # Apply method insertion aggressive
      #
      # @private
      # @param [Hash] options keyword options
      # @return [void]
      def apply_method_insertion_aggressive!(**options)
        rewriter = options[:rewriter]
        buffer = options[:buffer]
        insertion = options[:insertion]
        doc = options[:doc]

        remove_method_comment_block(rewriter, buffer, insertion)
        return if doc.nil? || doc.empty?

        rewriter.insert_before(options[:anchor_bol_range], doc)
        add_change(changes: options[:changes], type: :insert_full_doc_block,
                   insertion: insertion, file: options[:file], message: 'missing docs')
      end

      # Remove method comment block
      #
      # @private
      # @param [Parser::Source::TreeRewriter] rewriter the TreeRewriter accumulating source transformations
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @return [void]
      def remove_method_comment_block(rewriter, buffer, insertion)
        range = method_comment_block_removal_range(buffer, insertion)
        rewriter.remove(range) if range
      end

      # Apply method insertion safe
      #
      # @private
      # @param [Hash] options keyword options
      # @return [void]
      def apply_method_insertion_safe!(**options)
        info = method_doc_comment_info(options[:buffer], options[:insertion])

        if info
          apply_method_insertion_safe_with_info!(**options, info: info)
        else
          apply_method_insertion_safe_without_info!(**options)
        end
      end

      # Apply method insertion safe with info
      #
      # @private
      # @param [Hash] options keyword options
      # @return [void]
      def apply_method_insertion_safe_with_info!(**options)
        i = options[:info]
        dp = filter_doc_params(options)
        mr = DocBuilder.build_missing_merge_result( # steep:ignore
          options[:insertion], existing_lines: i[:doc_lines], strategy: options[:strategy], **dp
        )
        changed, n, ob = compute_doc_replacement(i, mr[:lines], strategy: options[:strategy], **dp)
        commit_safe_doc_outcome(options[:rewriter], options[:buffer], i, n,
                                old_block: ob, merge_result: mr, existing_order_changed: changed,
                                insertion: options[:insertion], changes: options[:changes], file: options[:file])
      end

      # Commit safe doc outcome
      #
      # @private
      # @param [Parser::Source::TreeRewriter] rewriter the TreeRewriter accumulating source transformations
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @param [Docscribe::InlineRewriter::docInfo] info hash containing existing doc comment block data
      # @param [String] new_block the newly constructed replacement doc block string
      # @param [Hash] rest additional kwargs (old_block, merge_result,
      # @return [void]
      def commit_safe_doc_outcome(rewriter, buffer, info, new_block, **rest)
        handle_doc_replacement(rewriter, buffer, info, new_block,
                               insertion: rest[:insertion], changes: rest[:changes],
                               file: rest[:file],
                               existing_order_changed: rest[:existing_order_changed])
        log_method_doc_changes!(insertion: rest[:insertion], merge_result: rest[:merge_result],
                                new_block: new_block, old_block: rest[:old_block],
                                changes: rest[:changes], file: rest[:file])
      end

      # Filter doc params
      #
      # @private
      # @param [Hash<Symbol, Object>] options the full options hash to filter
      # @return [Hash<Symbol, Object>]
      def filter_doc_params(options)
        options.reject { |k, _| %i[rewriter buffer insertion anchor_bol_range info changes file strategy].include?(k) }
      end

      # Handle doc replacement
      #
      # @private
      # @param [Parser::Source::TreeRewriter] rewriter the TreeRewriter accumulating source transformations
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @param [Docscribe::InlineRewriter::docInfo] info hash containing existing doc comment block data (start_pos, end_pos, lines)
      # @param [String] new_block the newly constructed replacement doc block string
      # @param [Hash] log_opts additional keyword arguments for logging and recording changes
      # @return [void]
      def handle_doc_replacement(rewriter, buffer, info, new_block, **log_opts)
        range = Parser::Source::Range.new(buffer, info[:start_pos], info[:end_pos])
        rewriter.replace(range, new_block)

        return unless log_opts[:existing_order_changed]

        add_change(changes: log_opts[:changes], type: :unsorted_tags,
                   insertion: log_opts[:insertion], file: log_opts[:file],
                   message: 'unsorted tags')
      end

      # Compute doc replacement
      #
      # @private
      # @param [Docscribe::InlineRewriter::docInfo] info existing doc info
      # @param [Array<String>] missing_lines new doc lines to add
      # @param [Hash] options keyword options
      # @return [(Boolean, String, String)]
      def compute_doc_replacement(info, missing_lines, **options)
        dc = options[:config]
        filter = filter_for_missing(info, missing_lines)
        sorted = Docscribe::InlineRewriter::DocBlock.merge(
          info[:doc_lines], missing_lines: [], sort_tags: dc.sort_tags?, tag_order: dc.tag_order
        )
        merged = Docscribe::InlineRewriter::DocBlock.merge(
          info[:doc_lines], missing_lines: missing_lines, sort_tags: dc.sort_tags?, tag_order: dc.tag_order,
                            filter_existing: filter
        )
        [sorted != info[:doc_lines], (info[:preserved_lines] + merged).join, info[:lines].join]
      end

      # Build filter for DocBlock.merge when missing lines replace existing invalid tags.
      #
      # @private
      # @param [Docscribe::InlineRewriter::docInfo] info parsed doc info from method_doc_comment_info
      # @param [Array<String>] missing_lines generated missing lines
      # @return [Hash<Symbol, Object>] filter for existing entries
      def filter_for_missing(info, missing_lines)
        filter = {} #: Hash[Symbol, untyped]
        doc_lines = Array(info[:doc_lines]) #: Array[String]
        filter[:return] = true if return_filter_needed?(doc_lines, missing_lines)
        names = param_names_for_filter(doc_lines, missing_lines)
        filter[:param_names] = names if names.any?
        filter
      end

      # Whether return filter is needed.
      #
      # @private
      # @param [Array<String>] doc_lines existing doc lines
      # @param [Array<String>] missing_lines generated missing lines
      # @return [Boolean]
      def return_filter_needed?(doc_lines, missing_lines)
        doc_lines.any? { |l| l.include?('@return') } && missing_lines.any? { |l| l.include?('@return') }
      end

      # Param names that need filtering.
      #
      # @private
      # @param [Array<String>] doc_lines existing doc lines
      # @param [Array<String>] missing_lines generated missing lines
      # @return [Array<String>]
      def param_names_for_filter(doc_lines, missing_lines)
        missing_names = missing_lines.filter_map { |l| extract_param_name_for_filter(l) }
        existing_names = doc_lines.filter_map { |l| extract_param_name_for_filter(l) }
        missing_names & existing_names
      end

      # Extract param name from a generated @param line for filtering.
      #
      # @private
      # @param [String] line generated param line
      # @return [String, nil]
      def extract_param_name_for_filter(line)
        content = line.sub(/^\s*#\s*/, '')
        if (m = content.match(/@param\s+(\S+)\s+\[/))
          return m[1]
        elsif (m = content.match(/@param\s+\[/))
          rest = content[(m.end(0) - 1)..] # steep:ignore
          type_end = rest.index(']') # steep:ignore
          return rest[(type_end + 1)..].to_s.strip.split(/\s+/).first if type_end # steep:ignore
        end

        nil
      end

      # Log method doc changes
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @param [Hash<Symbol, Object>] merge_result merge operation result
      # @param [Hash] rest additional keyword arguments forwarded to add_change
      # @return [void]
      def log_method_doc_changes!(insertion:, merge_result:, **rest)
        reason_specs = merge_result[:reasons] || []
        return unless doc_changed?(rest, reason_specs)

        log_reasons(reason_specs, insertion, rest)
      end

      # @private
      # @param [Hash<Symbol, Object>] rest
      # @param [Array<Hash<Symbol, Object>>] reason_specs
      # @return [Boolean]
      def doc_changed?(rest, reason_specs)
        rest[:new_block] != rest[:old_block] || type_mismatch_reasons?(reason_specs)
      end

      # @private
      # @param [Array<Hash<Symbol, Object>>] reason_specs
      # @return [Boolean]
      def type_mismatch_reasons?(reason_specs)
        reason_specs.any? { |r| type_mismatch_type?(r[:type]) }
      end

      # @private
      # @param [Symbol] type
      # @return [Boolean]
      def type_mismatch_type?(type)
        %i[updated_param updated_return invalid_type].include?(type)
      end

      # @private
      # @param [Array<Hash<Symbol, Object>>] reason_specs
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion
      # @param [Hash<Symbol, Object>] rest
      # @return [void]
      def log_reasons(reason_specs, insertion, rest)
        reason_specs.each { |reason| log_single_reason(reason, insertion, rest) }
      end

      # @private
      # @param [Hash<Symbol, Object>] reason
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion
      # @param [Hash<Symbol, Object>] rest
      # @return [void]
      def log_single_reason(reason, insertion, rest)
        add_change(changes: rest[:changes], type: reason[:type], insertion: insertion,
                   file: rest[:file], message: reason[:message], extra: extra_for_reason(reason))
      end

      # @private
      # @param [Hash<Symbol, Object>] reason
      # @return [Hash<Symbol, Object>]
      def extra_for_reason(reason)
        extra = (reason[:extra] || {}).dup
        extra[:source] = reason[:source] if reason[:source]
        extra
      end

      # Apply method insertion safe without info
      #
      # @private
      # @param [Hash] options keyword options
      # @return [void]
      def apply_method_insertion_safe_without_info!(**options)
        rewriter = options[:rewriter]
        insertion = options[:insertion]
        anchor_bol_range = options[:anchor_bol_range]
        doc = DocBuilder.build(insertion, **options.reject do |k, _|
          %i[rewriter buffer insertion anchor_bol_range changes file strategy].include?(k)
        end) # steep:ignore
        return if doc.nil? || doc.empty?

        rewriter.insert_before(anchor_bol_range, doc)
        add_change(changes: options[:changes], type: :insert_full_doc_block,
                   insertion: insertion, file: options[:file], message: 'missing docs')
      end

      # Filter options to keep only doc-building params for safe-without-info mode.
      # @private
      # @param [Hash[Symbol, untyped]] options the full options hash to filter
      # @return [Object]

      # Add change
      #
      # @private
      # @param [Hash] options kwargs for change record (type, file, line, method, message, insertion, changes, extra)
      # @return [void]
      def add_change(**options)
        changes = options[:changes]
        changes << {
          type: options[:type],
          file: options[:file],
          line: options[:line] || method_line_for(options[:insertion]),
          method: method_id_for(options[:insertion]),
          message: options[:message]
        }.merge(options[:extra] || {})
      end

      # Method id for
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @return [String]
      def method_id_for(insertion)
        name = SourceHelpers.node_name(insertion.node)
        "#{insertion.container}#{insertion.scope == :instance ? '#' : '.'}#{name}"
      end

      # Apply attr insertion
      #
      # @private
      # @param [Hash] options kwargs (insertion, config, rewriter, buffer, strategy,
      # @return [void]
      def apply_attr_insertion!(**options)
        config = options[:config]
        return unless config.respond_to?(:emit_attributes?) && config.emit_attributes?
        return unless attribute_allowed?(config, options[:insertion])

        bol_range = SourceHelpers.line_start_range(options[:buffer], options[:insertion].node)
        params = attr_insertion_params(options[:insertion], config, options[:signature_provider], bol_range)
        dispatch_attr_strategy(params, options)
      end

      # Attr insertion params
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] insertion the collected attribute insertion
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider external RBS signature provider
      # @param [Parser::Source::Range] bol_range the beginning-of-line range for the attribute node
      # @return [Hash<Symbol, Docscribe::InlineRewriter::Collector::AttrInsertion, Docscribe::Config, Docscribe::Types::ProviderChain, nil, Parser::Source::Range>] attr insertion params with keys
      #   :insertion, :config, :signature_provider, :bol_range
      def attr_insertion_params(insertion, config, signature_provider, bol_range)
        {
          insertion: insertion, config: config,
          signature_provider: signature_provider, bol_range: bol_range
        }
      end

      # Dispatch attr strategy
      #
      # @private
      # @param [Hash<Symbol, Object>] params precomputed attribute insertion parameters
      # @param [Hash<Symbol, Object>] options the full keyword options hash
      # @return [void]
      def dispatch_attr_strategy(params, options)
        case options[:strategy]
        when :aggressive then apply_attr_aggressive!(params, options[:rewriter], options[:buffer])
        when :safe then apply_attr_safe!(params, options[:merge_inserts], options[:rewriter], options[:buffer])
        end
      end

      # Apply attr aggressive
      #
      # @private
      # @param [Hash<Symbol, Object>] params precomputed attribute insertion parameters
      # @param [Parser::Source::TreeRewriter] rewriter the TreeRewriter accumulating source transformations
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @return [void]
      def apply_attr_aggressive!(params, rewriter, buffer)
        if (range = SourceHelpers.comment_block_removal_range(buffer, params[:bol_range].begin_pos))
          rewriter.remove(range)
        end

        doc = build_attr_doc_for_node(params[:insertion], config: params[:config],
                                                          signature_provider: params[:signature_provider])
        return if doc.nil? || doc.empty?

        rewriter.insert_before(params[:bol_range], doc)
      end

      # Apply attr safe
      #
      # @private
      # @param [Hash<Symbol, Object>] params precomputed attribute insertion parameters
      # @param [Hash<Integer, Array<(Integer, String)>>] merge_inserts deferred merge inserts
      # @param [Parser::Source::TreeRewriter] rewriter the TreeRewriter accumulating source transformations
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @return [void]
      def apply_attr_safe!(params, merge_inserts, rewriter, buffer)
        info = SourceHelpers.doc_comment_block_info(buffer, params[:bol_range].begin_pos)

        if info
          merge_attr_additions!(insertion: params[:insertion], info: info, merge_inserts: merge_inserts,
                                config: params[:config], signature_provider: params[:signature_provider])
          return
        end

        doc = build_attr_doc_for_node(params[:insertion], config: params[:config],
                                                          signature_provider: params[:signature_provider])
        return if doc.nil? || doc.empty?

        rewriter.insert_before(params[:bol_range], doc)
      end

      # Merge attr additions
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] insertion the collected attribute insertion
      # @param [Hash<Symbol, Object>] info hash containing existing doc comment block data
      # @param [Hash<Integer, Array<(Integer, String)>>] merge_inserts deferred merge inserts
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider external RBS signature provider
      # @return [Array<(Integer, String)>, nil]
      def merge_attr_additions!(insertion:, info:, merge_inserts:, config:, signature_provider:)
        additions = build_attr_merge_additions(ins: insertion, existing_lines: info[:lines],
                                               config: config, signature_provider: signature_provider)
        return unless additions && !additions.empty?

        merge_inserts[info[:end_pos]] << [insertion.node.loc.expression.begin_pos, additions]
      end

      # Apply merge inserts
      #
      # @private
      # @param [Parser::Source::TreeRewriter] rewriter the TreeRewriter accumulating source transformations
      # @param [Parser::Source::Buffer] buffer the source buffer being rewritten
      # @param [Hash<Integer, Array<(Integer, String)>>] merge_inserts deferred merge inserts
      # @return [void]
      def apply_merge_inserts!(rewriter:, buffer:, merge_inserts:)
        merge_inserts.keys.sort.reverse_each do |end_pos|
          text = merge_text_for_pos(merge_inserts[end_pos])
          next if text.nil? || text.empty?

          range = Parser::Source::Range.new(buffer, end_pos, end_pos)
          rewriter.insert_before(range, text)
        end
      end

      # Merge text for pos
      #
      # @private
      # @param [Array<(Integer, String)>] chunks merge chunks at position
      # @return [String, nil]
      def merge_text_for_pos(chunks)
        return nil if chunks.empty?

        chunks = chunks.sort_by { |(sort_key, _s)| sort_key }
        out_lines = [] #: Array[String]
        sep_re = /^\s*#\s*\r?\n$/

        chunks.each do |(_k, chunk)|
          next if chunk.nil? || chunk.empty?

          merge_chunk_into_out(chunk, out_lines, sep_re)
        end

        text = out_lines.join
        text.empty? ? nil : text
      end

      # Merge chunk into out
      #
      # @private
      # @param [String] chunk the doc text string to merge
      # @param [Array<String>] out_lines the accumulated output lines array
      # @param [Regexp] sep_re regex matching separator comment lines (# followed by newline)
      # @return [void]
      def merge_chunk_into_out(chunk, out_lines, sep_re)
        lines = chunk.lines
        seps = extract_separators(lines, sep_re)
        sep = seps.first
        out_lines << sep if sep && (out_lines.empty? || !out_lines.last.match?(sep_re))
        out_lines.concat(lines)
      end

      # Extract separators
      #
      # @private
      # @param [Array<String>] lines array of lines from the chunk
      # @param [Regexp] sep_re regex matching separator comment lines
      # @return [Array<String>]
      def extract_separators(lines, sep_re)
        seps = [] #: Array[String]
        seps << lines.shift while !lines.empty? && lines.first.match?(sep_re)
        seps
      end

      # Build attr merge additions
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [Array<String>] existing_lines array of existing doc comment lines
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider external RBS signature provider
      # @raise [StandardError]
      # @return [String, nil]
      # @return [nil] if StandardError
      def build_attr_merge_additions(ins:, existing_lines:, config:, signature_provider:)
        indent = SourceHelpers.line_indent(ins.node)
        lines = build_attr_merge_missing_lines(ins, existing_lines, indent, config, signature_provider)
        lines.concat(build_attr_merge_tag_lines(ins, existing_lines, indent, config, signature_provider))

        lines.empty? ? '' : lines.map { |l| "#{l}\n" }.join
      rescue StandardError
        nil
      end

      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins
      # @param [Array<String>] existing_lines
      # @param [String] indent
      # @param [Docscribe::Config] config
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider
      # @return [Array<String>]
      def build_attr_merge_missing_lines(ins, existing_lines, indent, config, signature_provider)
        missing = missing_attr_names(ins, existing_lines)
        lines = [] #: Array[String]

        unless missing.empty?
          lines << "#{indent}#" if existing_lines.any? && existing_lines.last.strip != '#'
          lines.concat(build_attr_doc_lines(ins, indent: indent, config: config,
                                                 signature_provider: signature_provider, names: missing))
        end

        lines
      end

      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins
      # @param [Array<String>] existing_lines
      # @param [String] indent
      # @param [Docscribe::Config] config
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider
      # @return [Array<String>]
      def build_attr_merge_tag_lines(ins, existing_lines, indent, config, signature_provider)
        tag_additions = build_missing_tag_additions(ins, existing_lines, indent, config, signature_provider)
        return [] if tag_additions.empty?

        result = [] #: Array[String]
        result << "#{indent}#" if existing_lines.any? && existing_lines.last.strip != '#'
        result.concat(tag_additions)
        result
      end

      # Missing attr names
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [Array<String>] existing_lines array of existing doc comment lines
      # @return [Array<Symbol>]
      def missing_attr_names(ins, existing_lines)
        existing = existing_attr_names(existing_lines)
        ins.names.reject { |name_sym| existing[name_sym.to_s] }
      end

      # Existing attr names
      #
      # @private
      # @param [Array<String>] lines array of existing doc comment lines
      # @return [Hash<String, Boolean>]
      def existing_attr_names(lines)
        names = {} #: Hash[String, bool]

        Array(lines).each do |line|
          if (m = line.match(/^\s*#\s*@!attribute\b(?:\s+\[[^\]]+\])?\s+(\S+)/))
            names[m[1].to_s] = true
          end
        end

        names
      end

      # Build missing tag additions for existing @!attribute lines
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [Array<String>] existing_lines array of existing doc comment lines
      # @param [String] indent whitespace indentation prefix
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider external RBS signature provider
      # @return [Array<String>]
      def build_missing_tag_additions(ins, existing_lines, indent, config, signature_provider)
        ins.names.each_with_object([]) do |name_sym, additions|
          idx = existing_attr_line_index(existing_lines, name_sym.to_s)
          next unless idx

          attr_type = attribute_type(ins, name_sym, config, signature_provider: signature_provider)
          additions << "#{indent}#   @return [#{attr_type}]" if attr_return_missing?(ins.access, existing_lines, idx)
          additions << format_attribute_param_tag(indent, 'value', attr_type, style: config.param_tag_style) if attr_param_missing?(ins.access, existing_lines, idx)
        end
      end

      # @private
      # @param [Symbol] access
      # @param [Array<String>] existing_lines
      # @param [Integer] idx
      # @return [Boolean]
      def attr_return_missing?(access, existing_lines, idx)
        %i[r rw].include?(access) && !existing_lines_contain_tag?(existing_lines, idx, 'return')
      end

      # @private
      # @param [Symbol] access
      # @param [Array<String>] existing_lines
      # @param [Integer] idx
      # @return [Boolean]
      def attr_param_missing?(access, existing_lines, idx)
        %i[w rw].include?(access) && !existing_lines_contain_tag?(existing_lines, idx, 'param')
      end

      # Find index of line containing @!attribute for a specific name
      #
      # @private
      # @param [Array<String>] lines array of existing doc comment lines
      # @param [String] name the attribute name to search for
      # @return [Integer?]
      def existing_attr_line_index(lines, name)
        Array(lines).each_with_index do |line, idx|
          return idx if line.match?(/\A\s*#\s*@!attribute\b(?:\s+\[[^\]]+\])?\s+#{Regexp.escape(name)}\b/)
        end
        nil
      end

      # Check if lines after an @!attribute line contain a specific tag
      #
      # Walks forward from attr_line_idx + 1, stopping at the next top-level
      # directive or non-comment line.
      #
      # @private
      # @param [Array<String>] lines array of existing doc comment lines
      # @param [Integer] attr_line_idx index of the @!attribute line
      # @param [String] tag_name the tag name to search for (e.g. "return", "param")
      # @return [Boolean]
      def existing_lines_contain_tag?(lines, attr_line_idx, tag_name)
        i = attr_line_idx + 1
        while i < lines.length
          line = lines[i]
          break unless line.match?(/\A\s*#/) # not a comment line
          break if line.match?(/\A\s*# @(?!@)/) # next top-level directive (single space)
          return true if line.match?(/\A\s*#\s{2,}@#{tag_name}\b/)

          i += 1
        end
        false
      end

      # Attribute allowed
      #
      # @private
      # @param [Docscribe::Config] config the active configuration
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @return [Boolean]
      def attribute_allowed?(config, ins)
        ins.names.any? do |name_sym|
          allowed_for_access?(config, ins, name_sym)
        end
      end

      # Allowed for access
      #
      # @private
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [Symbol] name_sym the attribute name as a Symbol
      # @return [Boolean]
      def allowed_for_access?(config, ins, name_sym)
        ok = false

        if %i[r rw].include?(ins.access)
          ok ||= config.process_method?(container: ins.container, scope: ins.scope,
                                        visibility: ins.visibility, name: name_sym)
        end

        if %i[w rw].include?(ins.access)
          ok ||= config.process_method?(container: ins.container, scope: ins.scope,
                                        visibility: ins.visibility, name: :"#{name_sym}=")
        end

        ok
      end

      # Build attr doc for node
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider external RBS signature provider
      # @raise [StandardError]
      # @return [String, nil]
      # @return [nil] if StandardError
      def build_attr_doc_for_node(ins, config:, signature_provider:)
        indent = SourceHelpers.line_indent(ins.node)
        lines = build_attr_doc_lines(ins, indent: indent, config: config, signature_provider: signature_provider)
        lines.map { |l| "#{l}\n" }.join
      rescue StandardError
        nil
      end

      # Build attr doc lines
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [String] indent whitespace indentation prefix derived from the attribute node
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider external RBS signature provider
      # @param [Array<Symbol>, nil?] names optional subset of attribute names to document (defaults to all names)
      # @return [Array<String>]
      def build_attr_doc_lines(ins, indent:, config:, signature_provider:, names: nil)
        names ||= ins.names
        lines = [] #: Array[untyped]

        names.each_with_index do |name_sym, idx|
          lines.concat(build_single_attr_lines(ins, name_sym, indent: indent,
                                                              config: config, signature_provider: signature_provider,
                                                              idx: idx, total: names.length))
        end

        lines
      end

      # Build single attr lines
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [Symbol] name_sym the attribute name as a Symbol
      # @param [String] indent whitespace indentation prefix
      # @param [Hash] opts additional keyword arguments forwarded from build_attr_doc_lines
      # @return [Array<String>]
      def build_single_attr_lines(ins, name_sym, indent:, **opts)
        cfg = opts[:config]
        attr_type = attribute_type(ins, name_sym, cfg, signature_provider: opts[:signature_provider])
        lines = ["#{indent}# @!attribute [#{ins.access}] #{name_sym}"]
        lines.concat(attr_visibility_lines(indent, cfg, ins))
        append_attr_return_tag(lines, indent, attr_type, ins.access)
        append_attr_param_tag(lines, indent, attr_type, ins.access, cfg)
        lines << "#{indent}#" if opts[:idx] < opts[:total] - 1
        lines
      end

      # Append attr return tag
      #
      # @private
      # @param [Array<String>] lines the doc lines array being built
      # @param [String] indent whitespace indentation prefix
      # @param [String] attr_type the resolved type string for the attribute
      # @param [Symbol] access the access level (:r, :w, or :rw)
      # @return [Array<String>, nil]
      def append_attr_return_tag(lines, indent, attr_type, access)
        lines << "#{indent}#   @return [#{attr_type}]" if %i[r rw].include?(access)
      end

      # Append attr param tag
      #
      # @private
      # @param [Array<String>] lines the doc lines array being built
      # @param [String] indent whitespace indentation prefix
      # @param [String] attr_type the resolved type string for the attribute
      # @param [Symbol] access the access level (:r, :w, or :rw)
      # @param [Docscribe::Config] cfg the active Docscribe::Config
      # @return [Array<String>, nil]
      def append_attr_param_tag(lines, indent, attr_type, access, cfg)
        return unless %i[w rw].include?(access)

        lines << format_attribute_param_tag(indent, 'value', attr_type, style: cfg.param_tag_style)
      end

      # Attr visibility lines
      #
      # @private
      # @param [String] indent whitespace indentation prefix
      # @param [Docscribe::Config] config the active Docscribe::Config
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @return [Array<String>]
      def attr_visibility_lines(indent, config, ins)
        return [] unless config.emit_visibility_tags?

        lines = [] #: Array[String]
        lines << "#{indent}# @private" if ins.visibility == :private
        lines << "#{indent}# @protected" if ins.visibility == :protected
        lines
      end

      # Format attribute param tag
      #
      # @private
      # @param [String] indent leading whitespace
      # @param [String] name attribute name
      # @param [String] type attribute type
      # @param [String, Symbol] style param tag style (`"name_type"` or `"type_name"`)
      # @return [String] formatted doc line
      def format_attribute_param_tag(indent, name, type, style:)
        type = type.to_s

        case style.to_s
        when 'name_type'
          "#{indent}#   @param #{name} [#{type}]"
        else
          "#{indent}#   @param [#{type}] #{name}"
        end
      end

      # Attribute type
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::AttrInsertion] ins the attribute insertion object
      # @param [Symbol] name_sym the attribute name as a Symbol
      # @param [Docscribe::Config] config the active configuration
      # @param [Docscribe::Types::ProviderChain, nil] signature_provider RBS signature provider
      # @raise [StandardError]
      # @return [String]
      # @return [String] if StandardError
      def attribute_type(ins, name_sym, config, signature_provider:)
        ty = config.fallback_type
        return ty unless signature_provider

        reader_sig = signature_provider.signature_for(container: ins.container, scope: ins.scope, name: name_sym)
        reader_sig&.return_type || ty
      rescue StandardError
        config.fallback_type
      end

      # Build signature provider
      #
      # @private
      # @param [Docscribe::Config] config the active configuration
      # @param [String] code the source code being processed
      # @param [String] file the file name
      # @raise [StandardError]
      # @return [Docscribe::Types::ProviderChain, Docscribe::Types::RBS::Provider, nil]
      # @return [Docscribe::Types::RBS::Provider, nil?] if StandardError
      def build_signature_provider(config, code, file)
        if config.respond_to?(:signature_provider_for)
          config.signature_provider_for(source: code, file: file)
        elsif config.respond_to?(:signature_provider)
          config.signature_provider # steep:ignore
        elsif config.respond_to?(:rbs_provider)
          config.rbs_provider
        end
      rescue StandardError
        config.respond_to?(:rbs_provider) ? config.rbs_provider : nil
      end

      # Method doc comment info
      #
      # @private
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @return [Docscribe::InlineRewriter::docInfo, nil] doc comment block info or nil
      def method_doc_comment_info(buffer, insertion)
        anchor_bol_range, def_bol_range = method_bol_ranges(buffer, insertion)

        SourceHelpers.doc_comment_block_info(buffer, anchor_bol_range.begin_pos) ||
          SourceHelpers.doc_comment_block_info(buffer, def_bol_range.begin_pos)
      end

      # Method comment block removal range
      #
      # @private
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @return [Parser::Source::Range, nil]
      def method_comment_block_removal_range(buffer, insertion)
        anchor_bol_range, def_bol_range = method_bol_ranges(buffer, insertion)

        SourceHelpers.comment_block_removal_range(buffer, anchor_bol_range.begin_pos) ||
          SourceHelpers.comment_block_removal_range(buffer, def_bol_range.begin_pos)
      end

      # Method bol ranges
      #
      # @private
      # @param [Parser::Source::Buffer] buffer the source buffer
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @return [(Parser::Source::Range, Parser::Source::Range)]
      def method_bol_ranges(buffer, insertion)
        anchor_node = anchor_node_for(insertion)
        [
          SourceHelpers.line_start_range(buffer, anchor_node),
          SourceHelpers.line_start_range(buffer, insertion.node)
        ]
      end

      # Method line for
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @raise [StandardError]
      # @return [Integer]
      # @return [Object] if StandardError
      def method_line_for(insertion)
        anchor_node_for(insertion).loc.expression.line
      rescue StandardError
        insertion.node.loc.expression.line
      end

      # Anchor node for
      #
      # @private
      # @param [Docscribe::InlineRewriter::Collector::Insertion] insertion the collected method insertion
      # @return [Parser::AST::Node]
      def anchor_node_for(insertion)
        if insertion.respond_to?(:anchor_node) && insertion.anchor_node
          insertion.anchor_node
        else
          insertion.node
        end
      end

      # Extract method override
      #
      # @private
      # @param [Docscribe::InlineRewriter::methodOverride, nil] method_override the raw override data
      # @return [Docscribe::InlineRewriter::methodOverride] normalized override hash
      def extract_method_override!(method_override)
        return {} unless method_override.is_a?(Hash)

        {
          return_type: method_override[:return_type],
          param_types: method_override[:param_types].is_a?(Hash) ? method_override[:param_types] : {},
          tags: normalize_override_tags(method_override[:tags])
        }
      end

      # Normalize override tags
      #
      # @private
      # @param [Array<Object>] tags raw tag values
      # @return [Array<Docscribe::Plugin::Tag>]
      def normalize_override_tags(tags)
        Array(tags).filter_map do |tag|
          case tag
          when Docscribe::Plugin::Tag then tag
          when Hash
            Docscribe::Plugin::Tag.new(**tag.transform_keys(&:to_sym))
          end
        end
      end
    end
  end
end

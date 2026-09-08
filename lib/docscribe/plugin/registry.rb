# frozen_string_literal: true

module Docscribe
  module Plugin
    # Global plugin registry.
    #
    # Plugins are registered once at boot time (e.g. in a file loaded via
    # `plugins.require:` in docscribe.yml) and called for every file Docscribe
    # processes.
    #
    # Thread safety: registration is expected to happen before any parallel
    # rewriting begins.
    module Registry
      # @!attribute [rw] plugin
      #   @return [Object]
      #   @param [Object] value
      #
      # @!attribute [rw] priority
      #   @return [Integer]
      #   @param [Integer] value
      #
      # @!attribute [rw] order
      #   @return [Integer]
      #   @param [Integer] value
      Entry = Struct.new(:plugin, :priority, :order, keyword_init: true)

      @tag_entries = []
      @collector_entries = []
      @order_seq = 0

      module_function

      # Register a plugin.
      #
      # Routes to the appropriate list based on plugin type:
      # - subclass of Base::TagPlugin       => tag plugin
      # - subclass of Base::CollectorPlugin => collector plugin
      # - responds to #call                 => tag plugin (duck typing)
      # - responds to #collect              => collector plugin (duck typing)
      #
      # @note module_function: defines #register (visibility: private)
      # @param [Object] plugin plugin instance
      # @param [Integer] priority plugin priority (higher wins for conflicts)
      # @return [void]
      def register(plugin, priority: 0)
        prio = parse_priority(priority)
        entry = create_entry(plugin, prio)
        route_entry(entry, plugin)
      end

      # Parse and validate plugin priority.
      #
      # @note module_function: defines #parse_priority (visibility: private)
      # @param [String, Integer] priority plugin priority (higher wins for conflicts)
      # @raise [StandardError]
      # @raise [ArgumentError]
      # @return [Integer]
      # @return [Object] if StandardError
      def parse_priority(priority)
        Integer(priority)
      rescue StandardError
        raise ArgumentError, "priority must be an Integer-like value, got: #{priority.inspect}"
      end

      # Create a new Entry with the next order number.
      #
      # @note module_function: defines #create_entry (visibility: private)
      # @param [Object] plugin plugin instance
      # @param [Integer] priority plugin priority (higher wins for conflicts)
      # @return [Docscribe::Plugin::Registry::Entry]
      def create_entry(plugin, priority)
        @order_seq += 1
        Entry.new(plugin: plugin, priority: priority, order: @order_seq)
      end

      # Route entry to tag or collector list.
      #
      # @note module_function: defines #route_entry (visibility: private)
      # @param [Docscribe::Plugin::Registry::Entry] entry the entry to route
      # @param [Object] plugin plugin instance
      # @raise [ArgumentError]
      # @return [void]
      def route_entry(entry, plugin)
        if plugin.is_a?(Base::CollectorPlugin) || plugin.respond_to?(:collect)
          @collector_entries << entry
        elsif plugin.is_a?(Base::TagPlugin) || plugin.respond_to?(:call)
          @tag_entries << entry
        else
          raise ArgumentError, 'Plugin must respond to #call (TagPlugin) or #collect (CollectorPlugin)'
        end
      end

      # All registered tag plugins in registration order.
      #
      # @note module_function: defines #tag_plugins (visibility: private)
      # @return [Array<Object>]
      def tag_plugins
        @tag_entries.map(&:plugin)
      end

      # All registered collector plugins in registration order.
      #
      # @note module_function: defines #collector_plugins (visibility: private)
      # @return [Array<Object>]
      def collector_plugins
        @collector_entries.map(&:plugin)
      end

      # All registered tag plugin entries (plugin + priority metadata).
      #
      # @note module_function: defines #tag_entries (visibility: private)
      # @return [Array<Docscribe::Plugin::Registry::Entry>]
      def tag_entries
        @tag_entries.dup
      end

      # All registered collector plugin entries (plugin + priority metadata).
      #
      # @note module_function: defines #collector_entries (visibility: private)
      # @return [Array<Docscribe::Plugin::Registry::Entry>]
      def collector_entries
        @collector_entries.dup
      end

      # Remove all registered plugins.
      #
      # Primarily used in tests to reset state between examples.
      #
      # @note module_function: defines #clear! (visibility: private)
      # @return [void]
      def clear!
        @tag_entries.clear
        @collector_entries.clear
        @order_seq = 0
        nil
      end
    end
  end
end

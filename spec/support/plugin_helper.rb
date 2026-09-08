# frozen_string_literal: true

module PluginHelper
  def build_plugin(anchor_type:, doc:)
    Class.new(TestCollectorPluginBase) do
      include TestPlugins::FindFirst

      def collect(ast, _buffer)
        node = find_first(ast, @anchor_type)
        return [] unless node

        [{ anchor_node: node, doc: @doc }]
      end
    end.new(anchor_type: anchor_type, doc: doc)
  end

  def build_override_plugin(return_type:, param_types: {}, tags: [])
    Class.new(TestCollectorPluginBase) do
      include TestPlugins::FindFirst

      def collect(ast, _buffer)
        node = find_first(ast, :defs) || find_first(ast, :def)
        return [] unless node

        [{ anchor_node: node, method_override: { return_type: @return_type, param_types: @param_types, tags: @tags } }]
      end
    end.new(return_type: return_type, param_types: param_types, tags: tags)
  end

  def build_collector_plugin(doc_line)
    Class.new(TestCollectorPluginBase) do
      include TestPlugins::FindFirstDef

      def collect(ast, _buffer)
        node = find_first_def(ast)
        return [] unless node

        [{ anchor_node: node, doc: @doc_line }]
      end
    end.new(doc_line: doc_line)
  end
end

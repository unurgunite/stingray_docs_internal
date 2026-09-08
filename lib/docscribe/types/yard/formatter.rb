# frozen_string_literal: true

require_relative 'types'

module Docscribe
  module Types
    module Yard
      # Converts YARD type AST to RBS type strings
      module Formatter
        class << self
          # @param [Docscribe::Types::Yard::node?] node
          # @return [String]
          def to_rbs(node)
            return 'untyped' if node.nil?

            rbs_for_node(node) || 'untyped'
          end

          private

          # @private
          # @param [Docscribe::Types::Yard::node] node
          # @return [String, nil]
          def rbs_for_node(node)
            simple_type(node) || composite_type(node) || collection_type(node)
          end

          # @private
          # @param [Docscribe::Types::Yard::node] node
          # @return [String, nil]
          def simple_type(node)
            case node
            when Named then format_named(node)
            when Literal then format_literal(node)
            end
          end

          # @private
          # @param [Docscribe::Types::Yard::node] node
          # @return [String, nil]
          def composite_type(node)
            case node
            when Union then format_union(node)
            when Intersection then format_intersection(node)
            when Optional then format_optional(node)
            end
          end

          # @private
          # @param [Docscribe::Types::Yard::node] node
          # @return [String, nil]
          def collection_type(node)
            case node
            when Generic then format_generic(node)
            when Tuple then format_tuple(node)
            when HashMap then format_hash_map(node)
            end
          end

          # @private
          # @param [Docscribe::Types::Yard::Named] node
          # @return [String]
          def format_named(node)
            case node.name
            when 'Boolean' then 'bool'
            when 'Object' then 'untyped'
            else node.name
            end
          end

          # @private
          # @param [Docscribe::Types::Yard::Generic] node
          # @return [String]
          def format_generic(node)
            "#{node.base}[#{node.args.map { |a| to_rbs(a) }.join(', ')}]"
          end

          # @private
          # @param [Docscribe::Types::Yard::Union] node
          # @return [String]
          def format_union(node)
            node.types.map { |t| to_rbs(t) }.join(' | ')
          end

          # @private
          # @param [Docscribe::Types::Yard::Intersection] node
          # @return [String]
          def format_intersection(node)
            node.types.map { |t| to_rbs(t) }.join(' & ')
          end

          # @private
          # @param [Docscribe::Types::Yard::Optional] node
          # @return [String]
          def format_optional(node)
            "#{to_rbs(node.type)}?"
          end

          # @private
          # @param [Docscribe::Types::Yard::Tuple] node
          # @return [String]
          def format_tuple(node)
            "[#{node.types.map { |t| to_rbs(t) }.join(', ')}]"
          end

          # @private
          # @param [Docscribe::Types::Yard::HashMap] node
          # @return [String]
          def format_hash_map(node)
            "Hash[#{to_rbs(node.key_type)}, #{to_rbs(node.value_type)}]"
          end

          # @private
          # @param [Docscribe::Types::Yard::Literal] node
          # @return [String]
          def format_literal(node)
            case node.value
            when 'void' then 'void'
            when 'nil' then 'nil'
            when 'self' then 'self'
            when 'true', 'false' then 'bool'
            else 'untyped'
            end
          end
        end
      end
    end
  end
end

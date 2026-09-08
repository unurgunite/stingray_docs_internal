# frozen_string_literal: true

module Docscribe
  module Infer
    # Analyzes method behavior (predicates, side effects, mutating calls).
    module Behavior
      MUTATING_METHODS = %i[<< push pop delete merge update write save create destroy
                            insert update_all delete_all].freeze

      class << self
        # @param [Parser::AST::Node, nil] body
        # @param [Symbol?] method_name
        # @return [Hash<Symbol, Boolean, String, nil>]
        def analyze(body, method_name)
          result = default_result(method_name)

          return result unless body.is_a?(Parser::AST::Node)

          analyze_body(body, result)
          result
        end

        # @param [Symbol?] method_name
        # @return [Hash<Symbol, Boolean, String, nil>]
        def default_result(method_name)
          {
            predicate: method_name&.to_s&.end_with?('?') || false,
            bang: method_name&.to_s&.end_with?('!') || false,
            has_side_effects: false,
            delegates: nil,
            returns_self: false,
            returns_boolean: false
          }
        end

        # @param [Hash<Symbol, Boolean, String, nil>] analysis
        # @param [Symbol?] _method_name
        # @return [String?]
        def infer_description(analysis, _method_name)
          return nil unless analysis[:has_side_effects] || analysis[:predicate]

          if analysis[:predicate]
            'Returns true if the condition is met, false otherwise'
          elsif analysis[:returns_self]
            'Returns self to allow method chaining'
          elsif analysis[:has_side_effects]
            nil
          end
        end

        private

        # @private
        # @param [Parser::AST::Node] node
        # @param [Hash<Symbol, Boolean, String, nil>] result
        # @return [void]
        def analyze_body(node, result)
          case node.type
          when :ivasgn, :ivar
            result[:has_side_effects] = true
          when :send
            analyze_send(node, result)
          when :self
            result[:returns_self] = true if result[:returns_self]
          end

          recurse_children(node, result)
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Hash<Symbol, Boolean, String, nil>] result
        # @return [void]
        def recurse_children(node, result)
          node.children.each do |child|
            analyze_body(child, result) if child.is_a?(Parser::AST::Node)
          end
        end

        # @private
        # @param [Parser::AST::Node] node
        # @param [Hash<Symbol, Boolean, String, nil>] result
        # @return [void]
        def analyze_send(node, result)
          _receiver, method_name = *node
          method_sym = method_name.is_a?(Symbol) ? method_name : nil
          return unless method_sym

          return unless MUTATING_METHODS.include?(method_sym)

          result[:has_side_effects] = true
        end
      end
    end
  end
end

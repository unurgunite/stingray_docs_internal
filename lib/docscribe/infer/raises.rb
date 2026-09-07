# frozen_string_literal: true

# rubocop:disable Style/EmptyElse, Lint/DuplicateBranch, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Lint/RedundantCopDisableDirective, Lint/MissingCopEnableDirective, Layout/EmptyLineAfterMagicComment
module Docscribe
  module Infer
    # Exception inference from AST (`raise`/`fail` calls and `rescue` clauses).
    module Raises
      module_function

      # Infer exception class names raised or rescued within a node.
      #
      # Sources considered:
      # - `rescue Foo, Bar`
      # - bare `rescue` (=> StandardError)
      # - `raise Foo`
      # - bare `raise` / `fail` (=> StandardError)
      #
      # Returns unique exception names in discovery order.
      #
      # @note module_function: defines #infer_raises_from_node (visibility: private)
      # @param [Parser::AST::Node] node method or expression node to inspect
      # @return [Array<String>]
      def infer_raises_from_node(node) # rubocop:disable Metrics/MethodLength
        raises = [] #: Array[String]

        ASTWalk.walk(node) do |n|
          case n&.type # rubocop:disable Style/EmptyElse
          when :resbody
            raises.concat(exception_names_from_rescue_list(n.children[0]))
          when :send
            collect_send_raise(raises, n)
          else
            # no-op for other node types
          end
        end

        raises.uniq
      end

      # Extract exception class names from a rescue exception list.
      #
      # Examples:
      # - nil => `[StandardError]`
      # - `Foo` => `["Foo"]`
      # - `[Foo, Bar]` => `["Foo", "Bar"]`
      #
      # @note module_function: defines #exception_names_from_rescue_list (visibility: private)
      # @param [Parser::AST::Node, nil] exc_list rescue exception list node
      # @return [Array<String>]
      def exception_names_from_rescue_list(exc_list) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Lint/DuplicateBranch
        if exc_list.nil?
          [DEFAULT_ERROR]
        elsif exc_list.is_a?(Parser::AST::Node) && exc_list&.type == :array
          (exc_list&.children || []).map { |e| Names.const_full_name(e) || DEFAULT_ERROR }
        elsif exc_list.is_a?(Parser::AST::Node)
          [Names.const_full_name(exc_list) || DEFAULT_ERROR]
        else
          [DEFAULT_ERROR]
        end
      end

      # Collect exception names from a `raise` or `fail` send node.
      #
      # @note module_function: defines #collect_send_raise (visibility: private)
      # @param [Array<String>] raises accumulator
      # @param [Parser::AST::Node] node send node
      # @return [void]
      def collect_send_raise(raises, node)
        recv, meth, *args = *node
        return unless recv.nil? && %i[raise fail].include?(meth)

        if args.empty?
          raises << DEFAULT_ERROR
        else
          c = Names.const_full_name(args[0])
          raises << (c || DEFAULT_ERROR)
        end
      end
    end
  end
end

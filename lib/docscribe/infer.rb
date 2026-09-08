# frozen_string_literal: true

# NOTE: parser/base references Racc::Parser in some environments, so require runtime first.
require 'racc/parser'
require 'ast'
require 'parser/ast/node'
require 'parser/source/buffer'
require 'parser/base'

require 'docscribe/parsing'

require_relative 'infer/constants'
require_relative 'infer/ast_walk'
require_relative 'infer/names'
require_relative 'infer/literals'
require_relative 'infer/params'
require_relative 'infer/returns'
require_relative 'infer/raises'
require_relative 'infer/behavior'

module Docscribe
  # Best-effort inference utilities used to generate YARD tags.
  #
  # This module is intentionally heuristic:
  # - it aims to be useful for common Ruby patterns
  # - it prefers safe fallback behavior when uncertain
  # - when inference cannot be specific, it falls back to `Object`
  #
  # External signature sources such as RBS and Sorbet are applied later in the
  # doc builder and can override these inferred types.
  module Infer
    class << self
      # Infer exception classes raised or rescued within an AST node.
      #
      # @param [Parser::AST::Node] node constant AST node to resolve
      # @return [Array<String>]
      def infer_raises_from_node(node)
        Raises.infer_raises_from_node(node)
      end

      # Analyze method behavior from AST node and method name.
      #
      # @param [Parser::AST::Node?] node def or defs node
      # @param [Symbol?] method_name
      # @return [Hash<Symbol, Boolean>]
      def analyze_behavior(node, method_name)
        body = extract_body(node)
        Behavior.analyze(body, method_name)
      end

      # Get behavioral description for a method.
      #
      # @param [Hash<Symbol, Boolean>] node def or defs node
      # @param [Symbol?] method_name
      # @return [String?]
      def infer_behavior_description(node, method_name)
        body = extract_body(node)
        return nil unless body

        analysis = Behavior.analyze(body, method_name)
        Behavior.infer_description(analysis, method_name)
      end

      # Extract method body from def/defs node.
      #
      # @param [Parser::AST::Node] node def or defs node
      # @return [Parser::AST::Node?]
      def extract_body(node)
        return nil unless node.is_a?(Parser::AST::Node)

        body_idx = node.type == :def ? 2 : 3
        node.children[body_idx]
      end

      # Infer a parameter type from its internal name form and optional default
      # expression.
      #
      # The internal parameter name may include:
      # - `*` for rest args
      # - `**` for keyword rest args
      # - `&` for block args
      # - trailing `:` for keyword args
      #
      # @param [String] name internal parameter name representation
      # @param [String?] default_str source for the default expression
      # @param [String] fallback_type default type when uncertain
      # @param [Boolean] treat_options_keyword_as_hash treat options: as Hash
      # @return [String]
      def infer_param_type(name, default_str, fallback_type: FALLBACK_TYPE, treat_options_keyword_as_hash: true)
        Params.infer_param_type(
          name,
          default_str,
          fallback_type: fallback_type,
          treat_options_keyword_as_hash: treat_options_keyword_as_hash
        )
      end

      # Parse a standalone expression source string for inference helpers.
      #
      # @param [String?] src expression source to parse
      # @return [Parser::AST::Node, nil]
      def parse_expr(src)
        Params.parse_expr(src)
      end

      # Infer a return type from full method source.
      #
      # @param [String?] method_source method definition source
      # @return [String]
      def infer_return_type(method_source)
        Returns.infer_return_type(method_source)
      end

      # Infer a return type from an already parsed `:def` / `:defs` node.
      #
      # @param [Parser::AST::Node] node constant AST node to resolve
      # @return [String]
      def infer_return_type_from_node(node)
        Returns.infer_return_type_from_node(node)
      end

      # Return structured normal/rescue return information for a method node.
      #
      # Result shape:
      # - `:normal` => the normal return type
      # - `:rescues` => rescue-branch conditional return info
      #
      # @param [Parser::AST::Node] node constant AST node to resolve
      # @param [String] fallback_type default type when uncertain
      # @param [Boolean] nil_as_optional render nil as optional
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider core RBS type lookup provider
      # @param [Hash<String, String>?] param_types parameter name -> type map
      # @param [String?] container
      # @param [Docscribe::Types::ProviderChain?] signature_provider
      # @return [Hash<Symbol, String, Array<(Array<String>, String)>>]
      def returns_spec_from_node(node, fallback_type: FALLBACK_TYPE, nil_as_optional: true, core_rbs_provider: nil, # rubocop:disable Metrics/ParameterLists
                                 param_types: nil, container: nil, signature_provider: nil)
        Returns.returns_spec_from_node(
          node,
          fallback_type: fallback_type,
          nil_as_optional: nil_as_optional,
          core_rbs_provider: core_rbs_provider,
          param_types: param_types,
          container: container,
          signature_provider: signature_provider
        )
      end

      # Infer the type of the last expression in an AST node.
      #
      # @param [Parser::AST::Node, nil] node constant AST node to resolve
      # @param [String] fallback_type default type when uncertain
      # @param [Boolean] nil_as_optional render nil as optional
      # @return [String, nil]
      def last_expr_type(node, fallback_type: FALLBACK_TYPE, nil_as_optional: true)
        Returns.last_expr_type(
          node,
          fallback_type: fallback_type,
          nil_as_optional: nil_as_optional
        )
      end

      # Convert a constant AST node into its fully qualified name.
      #
      # @param [Parser::AST::Node, nil] node constant AST node to resolve
      # @return [String, nil]
      def const_full_name(node)
        Names.const_full_name(node)
      end

      # Infer a YARD-ish type string from a literal AST node.
      #
      # @param [Parser::AST::Node, nil] node constant AST node to resolve
      # @param [String] fallback_type default type when uncertain
      # @return [String]
      def type_from_literal(node, fallback_type: FALLBACK_TYPE)
        Literals.type_from_literal(node, fallback_type: fallback_type)
      end

      # Unify two inferred type strings conservatively.
      #
      # @param [String, nil] type_a first type to unify
      # @param [String, nil] type_b second type to unify
      # @param [String] fallback_type default type when uncertain
      # @param [Boolean] nil_as_optional render nil as optional
      # @return [String]
      def unify_types(type_a, type_b, fallback_type: FALLBACK_TYPE, nil_as_optional: true)
        Returns.unify_types(
          type_a,
          type_b,
          fallback_type: fallback_type,
          nil_as_optional: nil_as_optional
        )
      end
    end
  end
end

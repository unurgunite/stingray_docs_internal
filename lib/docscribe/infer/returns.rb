# frozen_string_literal: true

require_relative '../types/primitive'

module Docscribe
  module Infer
    # Return type inference and rescue-conditional return extraction.
    module Returns
      module_function

      # Infer a return type from a full method definition source string.
      #
      # The source must parse to a `:def` or `:defs` node. If parsing fails or inference
      # is uncertain, the fallback type is returned.
      #
      # @note module_function: defines #infer_return_type (visibility: private)
      # @param [String?] method_source full method definition source
      # @raise [Parser::SyntaxError]
      # @return [String]
      # @return [Object] if Parser::SyntaxError
      def infer_return_type(method_source)
        return FALLBACK_TYPE if method_source.nil? || method_source.strip.empty?

        root = parse_method_source(method_source)
        return FALLBACK_TYPE unless root && %i[def defs].include?(root.type)

        body = root.children.last
        local_var_types = build_local_variable_types(body)
        run_last_expr_type(body, fallback_type: FALLBACK_TYPE, nil_as_optional: true,
                                 local_var_types: local_var_types) || FALLBACK_TYPE
      rescue Parser::SyntaxError
        FALLBACK_TYPE
      end

      # Parse a Ruby source string into an AST using the Parser gem.
      #
      # @note module_function: defines #parse_method_source (visibility: private)
      # @param [String] method_source the method definition source string to parse
      # @return [Parser::AST::Node, nil]
      def parse_method_source(method_source)
        buffer = Parser::Source::Buffer.new('(method)')
        buffer.source = method_source
        Docscribe::Parsing.parse_buffer(buffer)
      end

      # Infer a method's normal return type from an already parsed def/defs node.
      #
      # @note module_function: defines #infer_return_type_from_node (visibility: private)
      # @param [Parser::AST::Node] node `:def` or `:defs` node
      # @return [String]
      def infer_return_type_from_node(node)
        body = extract_def_body(node)
        return FALLBACK_TYPE unless body

        local_var_types = build_local_variable_types(body)
        run_last_expr_type(body, fallback_type: FALLBACK_TYPE, nil_as_optional: true,
                                 local_var_types: local_var_types) || FALLBACK_TYPE
      end

      # Return a structured return-type spec for a method node.
      #
      # The result includes:
      # - `:normal`  => normal/happy-path return type
      # - `:rescues` => array of `[exception_names, return_type]` pairs for rescue branches
      #
      # @note module_function: defines #returns_spec_from_node (visibility: private)
      # @param [Parser::AST::Node] node `:def` or `:defs` node
      # @param [String] fallback_type type used when inference is uncertain
      # @param [Boolean] nil_as_optional whether `nil` unions should be rendered as optional types
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider core RBS type lookup provider
      # @param [Hash<String, String>?] param_types parameter name -> type map
      # @param [String?] container
      # @param [Docscribe::Types::ProviderChain?] signature_provider
      # @return [Hash<Symbol, Object>]
      def returns_spec_from_node(node, fallback_type: FALLBACK_TYPE, nil_as_optional: true, core_rbs_provider: nil, # rubocop:disable Metrics/ParameterLists
                                 param_types: nil, container: nil, signature_provider: nil)
        body = extract_def_body(node)
        spec = { normal: FALLBACK_TYPE, rescues: [] } #: Hash[Symbol, untyped]
        return spec unless body

        types = build_local_variable_types(body, core_rbs_provider: core_rbs_provider, param_types: param_types)
        populate_returns_spec(spec, body, types, fallback_type: fallback_type, nil_as_optional: nil_as_optional,
                                                 core_rbs_provider: core_rbs_provider, param_types: param_types,
                                                 container: container, signature_provider: signature_provider)
        spec
      end

      # Extract the body child node from a `:def` or `:defs` AST node.
      #
      # @note module_function: defines #extract_def_body (visibility: private)
      # @param [Parser::AST::Node] node a `:def` or `:defs` AST node
      # @return [Parser::AST::Node, nil]
      def extract_def_body(node)
        case node.type
        when :def then node.children[2]
        when :defs then node.children[3]
        end
      end

      # Populate the spec hash with normal and/or rescue return types from the body.
      #
      # @note module_function: defines #populate_returns_spec (visibility: private)
      # @param [Hash<Symbol, Object>] spec the return spec hash to populate
      # @param [Parser::AST::Node] body the method body AST node
      # @param [Hash<String, String>?] local_var_types inferred local variable type map
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [void]
      def populate_returns_spec(spec, body, local_var_types, **opts)
        if body.type == :rescue
          process_rescue_body(spec, body, **opts)
        else
          spec[:normal] = infer_normal_return_type(body, **opts, local_var_types: local_var_types)
        end
      end

      # Infer the normal (non-rescue) return type from a method body node.
      #
      # @note module_function: defines #infer_normal_return_type (visibility: private)
      # @param [Parser::AST::Node] body the method body AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String]
      def infer_normal_return_type(body, **opts)
        run_last_expr_type(body, **opts) || FALLBACK_TYPE
      end

      # Process a :rescue body node and populate spec with normal + rescue return types.
      #
      # @note module_function: defines #process_rescue_body (visibility: private)
      # @param [Hash<Symbol, Object>] spec the return spec hash to populate
      # @param [Parser::AST::Node] body the :rescue AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [void]
      def process_rescue_body(spec, body, **opts)
        main_body = body.children[0]
        local_var_types = build_local_variable_types(body,
                                                     core_rbs_provider: opts[:core_rbs_provider],
                                                     param_types: opts[:param_types])
        rescue_opts = opts.merge(local_var_types: local_var_types)
        spec[:normal] = run_last_expr_type(main_body, **rescue_opts) || FALLBACK_TYPE
        process_rescue_branches(spec, body, **rescue_opts)
      end

      # Extract return types from each :resbody child and append to spec[:rescues].
      #
      # @note module_function: defines #process_rescue_branches (visibility: private)
      # @param [Hash<Symbol, Object>] spec the return spec hash to populate
      # @param [Parser::AST::Node] body the :rescue AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [void]
      def process_rescue_branches(spec, body, **opts)
        body.children.each do |ch|
          next unless ch.is_a?(Parser::AST::Node) && ch.type == :resbody

          exc_list, _asgn, rescue_body = *ch
          exc_names = Raises.exception_names_from_rescue_list(exc_list)
          rtype = run_last_expr_type(rescue_body, **opts) || opts[:fallback_type]
          spec[:rescues] << [exc_names, rtype]
        end
      end

      # Build a map of local/global/ivar/constant assignments to inferred types.
      #
      # @note module_function: defines #build_local_variable_types (visibility: private)
      # @param [Parser::AST::Node] node AST node to walk
      # @param [Hash] opts additional keyword options forwarded to inference
      # @return [Hash<String, String>, nil]
      def build_local_variable_types(node, **opts)
        types = {} #: Hash[String, String]
        ASTWalk.walk(node) do |n|
          collect_assignment_type(n, types, **opts)
        end
        types.empty? ? nil : types
      end

      # Infer the type of a single assignment node and store it in the types hash.
      #
      # Uses `run_last_expr_type` when `core_rbs_provider` is available to
      # resolve send expressions (e.g., `x = 123 + 1` -> `Integer`).
      # Falls back to `Literals.type_from_literal` for plain literals.
      #
      # @note module_function: defines #collect_assignment_type (visibility: private)
      # @param [Parser::AST::Node] node an assignment AST node
      # @param [Hash<String, String>] types the accumulated local variable type map
      # @param [Hash] opts additional keyword options forwarded to inference
      # @return [void]
      def collect_assignment_type(node, types, **opts)
        name, value = assignment_name_and_value(node)
        return unless name && value

        inferred = if node.type == :op_asgn
                     assignment_op_asgn_type(node, types, **opts)
                   else
                     assignment_inferred_type(value, types, **opts)
                   end
        types[name] = inferred if inferred && inferred != FALLBACK_TYPE
      end

      # @note module_function: defines #assignment_inferred_type (visibility: private)
      # @param [Parser::AST::Node] value
      # @param [Hash<String, String>] types
      # @param [Hash] opts
      # @return [String, nil]
      def assignment_inferred_type(value, types, **opts)
        run_last_expr_type(value, fallback_type: FALLBACK_TYPE, nil_as_optional: false, local_var_types: types,
                                  core_rbs_provider: opts[:core_rbs_provider], param_types: opts[:param_types],
                                  signature_provider: opts[:signature_provider], container: opts[:container])
      end

      # @note module_function: defines #assignment_op_asgn_type (visibility: private)
      # @param [Parser::AST::Node] node
      # @param [Hash<String, String>] types
      # @param [Hash] opts
      # @return [String, nil]
      def assignment_op_asgn_type(node, types, **opts)
        run_last_expr_type(node, fallback_type: FALLBACK_TYPE, nil_as_optional: false, local_var_types: types,
                                 core_rbs_provider: opts[:core_rbs_provider], param_types: opts[:param_types],
                                 signature_provider: opts[:signature_provider], container: opts[:container])
      end

      # Extract the variable name and value expression from an assignment node.
      #
      # @note module_function: defines #assignment_name_and_value (visibility: private)
      # @param [Parser::AST::Node] node an assignment AST node (:lvasgn, :gvasgn, :ivasgn, :casgn, :op_asgn)
      # @return [(String, nil, Parser::AST::Node, nil)]
      def assignment_name_and_value(node)
        case node.type
        when :lvasgn, :gvasgn, :ivasgn, :cvasgn
          [node.children[0].to_s, node.children[1]]
        when :casgn
          constant_name_and_value(node)
        when :op_asgn
          compound_name_and_value(node)
        else
          [nil, nil]
        end
      end

      # Extract the name and value from a `:casgn` (constant assignment) node.
      #
      # @note module_function: defines #constant_name_and_value (visibility: private)
      # @param [Parser::AST::Node] node the `:casgn` AST node
      # @return [(String, nil, Parser::AST::Node, nil)]
      def constant_name_and_value(node)
        [node.children[0].to_s, node.children[2]]
      end

      # Extract the name and value from an `:op_asgn` (compound assignment) node.
      #
      # @note module_function: defines #compound_name_and_value (visibility: private)
      # @param [Parser::AST::Node] node the `:op_asgn` AST node
      # @return [(String, nil, Parser::AST::Node, nil)]
      def compound_name_and_value(node)
        [node.children[0].children.first.to_s, node.children[2]]
      end

      # Handle `:lvar` node for last_expr_type — look up the variable in local_var_types.
      #
      # @note module_function: defines #handle_lvar_node (visibility: private)
      # @param [Parser::AST::Node] node the `:lvar` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_lvar_node(node, **opts)
        name = node.children[0].to_s
        lookup_lvar_type(name, opts[:local_var_types], opts[:param_types]) || opts[:fallback_type]
      end

      # Handle `:ivar` node for last_expr_type — look up instance variable in local_var_types.
      #
      # @note module_function: defines #handle_ivar_node (visibility: private)
      # @param [Parser::AST::Node] node the `:ivar` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_ivar_node(node, **opts)
        name = node.children[0].to_s
        opts[:local_var_types]&.fetch(name, nil) || opts[:fallback_type]
      end

      # Handle `:gvar` node for last_expr_type — look up global variable in local_var_types.
      #
      # @note module_function: defines #handle_gvar_node (visibility: private)
      # @param [Parser::AST::Node] node the `:gvar` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_gvar_node(node, **opts)
        name = node.children[0].to_s
        opts[:local_var_types]&.fetch(name, nil) || opts[:fallback_type]
      end

      # Handle `:cvar` node for last_expr_type — look up class variable in local_var_types.
      #
      # @note module_function: defines #handle_cvar_node (visibility: private)
      # @param [Parser::AST::Node] node the `:cvar` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_cvar_node(node, **opts)
        name = node.children[0].to_s
        opts[:local_var_types]&.fetch(name, nil) || opts[:fallback_type]
      end

      # Handle `:lvasgn` node for last_expr_type — look up local var assignment in local_var_types.
      #
      # @note module_function: defines #handle_lvasgn_node (visibility: private)
      # @param [Parser::AST::Node] node the `:lvasgn` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_lvasgn_node(node, **opts)
        name = node.children[0].to_s
        opts[:local_var_types]&.fetch(name, nil) ||
          run_last_expr_type(node.children[1], **opts) ||
          opts[:fallback_type]
      end

      # Handle `:ivasgn` node for last_expr_type — look up ivar assignment in local_var_types.
      #
      # @note module_function: defines #handle_ivasgn_node (visibility: private)
      # @param [Parser::AST::Node] node the `:ivasgn` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_ivasgn_node(node, **opts)
        name = node.children[0].to_s
        opts[:local_var_types]&.fetch(name, nil) ||
          run_last_expr_type(node.children[1], **opts) ||
          opts[:fallback_type]
      end

      # Handle `:gvasgn` node for last_expr_type — look up global var assignment in local_var_types.
      #
      # @note module_function: defines #handle_gvasgn_node (visibility: private)
      # @param [Parser::AST::Node] node the `:gvasgn` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_gvasgn_node(node, **opts)
        name = node.children[0].to_s
        opts[:local_var_types]&.fetch(name, nil) ||
          run_last_expr_type(node.children[1], **opts) ||
          opts[:fallback_type]
      end

      # Handle `:cvasgn` node for last_expr_type — look up class var assignment in local_var_types.
      #
      # @note module_function: defines #handle_cvasgn_node (visibility: private)
      # @param [Parser::AST::Node] node the `:cvasgn` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_cvasgn_node(node, **opts)
        name = node.children[0].to_s
        opts[:local_var_types]&.fetch(name, nil) ||
          run_last_expr_type(node.children[1], **opts) ||
          opts[:fallback_type]
      end

      # Handle `:op_asgn` node (compound assignment: `x += 1`, `@var -= 2`, etc.).
      #
      # RBS -> Infer: try RBS for meth on receiver type, else unify left/right
      # keeping String? via nil_as_optional:true. No hardcoded operator list.
      #
      # @note module_function: defines #handle_op_asgn_node (visibility: private)
      # @param [Parser::AST::Node] node the `:op_asgn` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_op_asgn_node(node, **opts)
        meth = node.children[1]
        lhs = node.children[0]
        rhs = node.children[2]
        left = op_asgn_left_type(lhs, **opts)
        right = op_asgn_right_type(rhs, **opts)
        rbs = op_asgn_rbs_type(lhs, left, meth, **opts)
        return rbs if rbs

        op_asgn_fallback_type(left, right, meth, **opts)
      end

      # @note module_function: defines #op_asgn_left_type (visibility: private)
      # @param [Parser::AST::Node, nil] lhs the lhs target node
      # @param [Hash] opts
      # @return [String, nil]
      def op_asgn_left_type(lhs, **opts)
        name = op_asgn_var_name(lhs)
        if name
          found = op_asgn_lookup_type(lhs, name, **opts)
          return found if found
        end
        run_last_expr_type(lhs, **op_asgn_expr_opts(**opts))
      end

      # @note module_function: defines #op_asgn_var_name (visibility: private)
      # @param [Parser::AST::Node, nil] lhs
      # @return [String, nil]
      def op_asgn_var_name(lhs)
        return nil unless lhs.is_a?(Parser::AST::Node)

        case lhs.type
        when :lvasgn, :ivasgn, :gvasgn, :cvasgn then lhs.children[0].to_s
        when :casgn then lhs.children[1].to_s
        end
      end

      # @note module_function: defines #op_asgn_lookup_type (visibility: private)
      # @param [Parser::AST::Node] lhs
      # @param [String] name
      # @param [Hash] opts
      # @return [String, nil]
      def op_asgn_lookup_type(lhs, name, **opts)
        case lhs.type
        when :lvasgn
          lookup_lvar_type(name, opts[:local_var_types], opts[:param_types])
        when :ivasgn, :gvasgn, :cvasgn, :casgn
          opts[:local_var_types]&.fetch(name, nil)
        end
      end

      # @note module_function: defines #op_asgn_right_type (visibility: private)
      # @param [Parser::AST::Node, nil] rhs
      # @param [Hash] opts
      # @return [String, nil]
      def op_asgn_right_type(rhs, **opts)
        return nil unless rhs

        run_last_expr_type(rhs, **op_asgn_expr_opts(**opts))
      end

      # @note module_function: defines #op_asgn_expr_opts (visibility: private)
      # @param [Hash] opts
      # @return [Hash<Symbol, Object>]
      def op_asgn_expr_opts(**opts)
        {
          fallback_type: opts[:fallback_type] || FALLBACK_TYPE,
          nil_as_optional: true,
          local_var_types: opts[:local_var_types],
          param_types: opts[:param_types],
          core_rbs_provider: opts[:core_rbs_provider],
          signature_provider: opts[:signature_provider],
          container: opts[:container]
        }
      end

      # @note module_function: defines #op_asgn_rbs_type (visibility: private)
      # @param [Parser::AST::Node, nil] lhs
      # @param [String, nil] left
      # @param [Symbol] meth
      # @param [Hash] opts
      # @return [String, nil]
      def op_asgn_rbs_type(lhs, left, meth, **opts)
        recv = cleaned_recv_type(left) ||
               receiver_rbs_type_name(lhs, opts[:core_rbs_provider],
                                      opts[:local_var_types], opts[:param_types])
        return nil unless recv && meth

        resolve_op_asgn_rbs(recv, meth, **opts)
      end

      # @note module_function: defines #resolve_op_asgn_rbs (visibility: private)
      # @param [String] recv_type
      # @param [Symbol] meth
      # @param [Hash] opts
      # @return [String, nil]
      def resolve_op_asgn_rbs(recv_type, meth, **opts)
        if opts[:core_rbs_provider]
          rbs = resolve_rbs_return_type(recv_type, meth, opts[:core_rbs_provider])
          return substitute_rbs_type(rbs, recv_type) unless rbs == FALLBACK_TYPE
        end
        if opts[:signature_provider]
          sig = opts[:signature_provider].signature_for(container: recv_type, scope: :instance, name: meth)
          return substitute_rbs_type(sig.return_type, recv_type) if sig
        end
        nil
      end

      # @note module_function: defines #op_asgn_fallback_type (visibility: private)
      # @param [String, nil] left
      # @param [String, nil] right
      # @param [Symbol] meth
      # @param [Hash] opts
      # @return [String, nil]
      def op_asgn_fallback_type(left, right, meth, **opts)
        fallback = (opts[:fallback_type] || FALLBACK_TYPE).to_s
        return synthesize_shovel_type(left, right, fallback: fallback) if shovel_method?(left, meth, opts[:core_rbs_provider])

        fallback_concrete_type(left, right, fallback) ||
          unify_types(left, right, fallback_type: fallback, nil_as_optional: true)
      end

      # Handle `:begin` node for last_expr_type.
      #
      # @note module_function: defines #handle_begin_node (visibility: private)
      # @param [Parser::AST::Node] node the `:return` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_begin_node(node, **opts)
        run_last_expr_type(node.children.last, **opts)
      end

      # Handle `:if` node for last_expr_type.
      #
      # @note module_function: defines #handle_if_node (visibility: private)
      # @param [Parser::AST::Node] node the `:return` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_if_node(node, **opts)
        t = run_last_expr_type(node.children[1], **opts)
        e = if node.children[2]
              run_last_expr_type(node.children[2], **opts)
            else
              'nil'
            end
        unify_types(t, e, fallback_type: opts[:fallback_type] || 'untyped',
                          nil_as_optional: opts.fetch(:nil_as_optional, true))
      end

      # Handle `:case` node for last_expr_type.
      #
      # @note module_function: defines #handle_case_node (visibility: private)
      # @param [Parser::AST::Node] node the `:return` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_case_node(node, **opts)
        branches = process_case_branches(node, **opts)
        if branches.empty?
          opts[:fallback_type]
        else
          branches.reduce do |a, b|
            unify_types(a, b, fallback_type: opts[:fallback_type] || 'untyped',
                              nil_as_optional: opts.fetch(:nil_as_optional, true))
          end
        end
      end

      # Handle `:or` node (`a || b`) for last_expr_type.
      #
      # The result type is the union of both sides, since either may be returned
      # depending on the truthiness of the left operand.
      #
      # @note module_function: defines #handle_or_node (visibility: private)
      # @param [Parser::AST::Node] node the `:or` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_or_node(node, **opts)
        t = run_last_expr_type(node.children[0], **opts)
        e = run_last_expr_type(node.children[1], **opts)
        fallback = opts[:fallback_type] || 'untyped'
        # If one side is the fallback alias (FALLBACK_TYPE / fallback_type) and the other is concrete, prefer the concrete
        # This prevents `sig&.return_type || FALLBACK_TYPE` from becoming `String, Object` when String is known
        if fallback_alias?(t, fallback) && !fallback_alias?(e, fallback)
          return e
        elsif fallback_alias?(e, fallback) && !fallback_alias?(t, fallback)
          return t
        end

        unify_types(t, e, fallback_type: fallback,
                          nil_as_optional: opts.fetch(:nil_as_optional, true))
      end

      # Handle `:and` node (`a && b`) for last_expr_type.
      #
      # The result type is the union of both sides, since either may be returned
      # depending on the truthiness of the left operand.
      #
      # @note module_function: defines #handle_and_node (visibility: private)
      # @param [Parser::AST::Node] node the `:and` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_and_node(node, **opts)
        t = run_last_expr_type(node.children[0], **opts)
        e = run_last_expr_type(node.children[1], **opts)
        unify_types(t, e, fallback_type: opts[:fallback_type] || 'untyped',
                          nil_as_optional: opts.fetch(:nil_as_optional, true))
      end

      # Handle `:kwbegin` node (`begin; expr; end`) for last_expr_type.
      #
      # Unwraps the explicit begin node and delegates to the inner expression,
      # which may be a `:rescue` or `:ensure` node.
      #
      # @note module_function: defines #handle_kwbegin_node (visibility: private)
      # @param [Parser::AST::Node] node the `:kwbegin` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_kwbegin_node(node, **opts)
        run_last_expr_type(node.children.first, **opts)
      end

      # Handle `:rescue` node for last_expr_type.
      #
      # Supports both inline rescue (`expr rescue default`) and block rescue
      # (`begin; expr; rescue; e; end`).
      #
      # @note module_function: defines #handle_rescue_node (visibility: private)
      # @param [Parser::AST::Node] node the `:rescue` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_rescue_node(node, **opts)
        branches = collect_rescue_branches(node, **opts)
        branches.reduce do |a, b|
          unify_types(a, b, fallback_type: opts[:fallback_type] || 'untyped',
                            nil_as_optional: opts.fetch(:nil_as_optional, true))
        end
      end

      # Handle `:rescue` node for last_expr_type.
      #
      # Unifies the body type with all rescue handler types and the optional else clause.
      # Collect all rescue branch return types from a `:rescue` AST node.
      #
      # @note module_function: defines #collect_rescue_branches (visibility: private)
      # @param [Parser::AST::Node] node the `:rescue` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [Array<String, nil>]
      def collect_rescue_branches(node, **opts)
        branches = [run_last_expr_type(node.children[0], **opts)]
        (node.children[1..] || []).each do |child|
          if child.is_a?(Parser::AST::Node) && child.type == :resbody
            handler = child.children[2]
            branches << run_last_expr_type(handler, **opts) if handler
          else
            branches << run_last_expr_type(child, **opts)
          end
        end
        branches
      end

      # Handle `:ensure` node (`begin; expr; ensure; cleanup; end`) for last_expr_type.
      #
      # The ensure clause's result is discarded by Ruby; only the body type is returned.
      #
      # @note module_function: defines #handle_ensure_node (visibility: private)
      # @param [Parser::AST::Node] node the `:ensure` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_ensure_node(node, **opts)
        run_last_expr_type(node.children[0], **opts)
      end

      # Handle `:defined?` node (`defined?(expr)`) for last_expr_type.
      #
      # Returns `nil` if the expression is not defined, or a String description
      # if it is defined. The union type is `String?`.
      #
      # @note module_function: defines #handle_defined_node (visibility: private)
      # @param [Parser::AST::Node] _node the `:defined?` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_defined_node(_node, **opts)
        nil_as_optional = opts.fetch(:nil_as_optional, true)
        nil_as_optional ? 'String?' : 'String, nil'
      end

      # Handle `:zsuper` node (`super` with no arguments) for last_expr_type.
      #
      # Returns the super method's return type if resolvable via RBS, or the
      # fallback type otherwise.
      #
      # @note module_function: defines #handle_zsuper_node (visibility: private)
      # @param [Parser::AST::Node] _node the `:zsuper` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_zsuper_node(_node, **opts)
        opts[:fallback_type]
      end

      # Handle `:super` node (`super(args)`) for last_expr_type.
      #
      # Returns the super method's return type if resolvable via RBS, or the
      # fallback type otherwise.
      #
      # @note module_function: defines #handle_super_node (visibility: private)
      # @param [Parser::AST::Node] _node the `:super` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_super_node(_node, **opts)
        opts[:fallback_type]
      end

      # Handle `:yield` node (`yield` / `yield(args)`) for last_expr_type.
      #
      # Returns the block's return type if resolvable via RBS (`Proc#call`),
      # or the fallback type otherwise.
      #
      # @note module_function: defines #handle_yield_node (visibility: private)
      # @param [Parser::AST::Node] _node the `:yield` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_yield_node(_node, **opts)
        opts[:fallback_type]
      end

      # Handle `:case_match` node (`case x; in pat; expr; end`) for last_expr_type.
      #
      # Similar to `:case` — unifies all `in_pattern` branch types and the optional else clause.
      #
      # @note module_function: defines #handle_case_match_node (visibility: private)
      # @param [Parser::AST::Node] node the `:case_match` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_case_match_node(node, **opts)
        branches = process_pattern_branches(node, **opts)
        if branches.empty?
          opts[:fallback_type]
        else
          branches.reduce do |a, b|
            unify_types(a, b, fallback_type: opts[:fallback_type] || 'untyped',
                              nil_as_optional: opts.fetch(:nil_as_optional, true))
          end
        end
      end

      # Handle `:in_pattern` node (pattern inside `case...in`) for last_expr_type.
      #
      # Extracts the body expression from the pattern and recurses.
      #
      # @note module_function: defines #handle_in_pattern_node (visibility: private)
      # @param [Parser::AST::Node] node the `:in_pattern` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_in_pattern_node(node, **opts)
        run_last_expr_type(node.children[2], **opts)
      end

      # Extract inferred return types from all in_pattern branches of a :case_match expression.
      #
      # @note module_function: defines #process_pattern_branches (visibility: private)
      # @param [Parser::AST::Node] node the :case_match AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [Array<String>] list of inferred types from each branch
      def process_pattern_branches(node, **opts)
        (node.children[1..] || []).compact.filter_map do |child|
          run_last_expr_type(child, **opts) if child.is_a?(Parser::AST::Node)
        end
      end

      # Extract inferred return types from all branches of a :case expression.
      #
      # @note module_function: defines #process_case_branches (visibility: private)
      # @param [Parser::AST::Node] node the :case AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [Array<String>] list of inferred types from each branch
      def process_case_branches(node, **opts)
        (node.children[1..] || []).compact.flat_map do |child|
          if child.type == :when
            run_last_expr_type(child.children.last, **opts)
          else
            run_last_expr_type(child, **opts)
          end
        end.compact
      end

      # Handle `:block` node for last_expr_type.
      #
      # @note module_function: defines #handle_block_node (visibility: private)
      # @param [Parser::AST::Node] node the `:return` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_block_node(node, **opts)
        send_node = node.children[0]
        return run_last_expr_type(node.children[2], **opts) unless send_node&.type == :send

        meth = send_node.children[1]
        handle_then_block(node, meth, **opts) ||
          block_send_rbs_type(node, send_node, **opts) ||
          handle_map_block(node, meth, **opts) ||
          run_last_expr_type(node.children[2], **opts)
      end

      # @note module_function: defines #handle_then_block (visibility: private)
      # @param [Parser::AST::Node] node
      # @param [Symbol] meth
      # @param [Hash] opts
      # @return [String, nil]
      def handle_then_block(node, meth, **opts)
        return nil unless %i[then yield_self].include?(meth)

        run_last_expr_type(node.children[2], **opts)
      end

      # @note module_function: defines #handle_map_block (visibility: private)
      # @param [Parser::AST::Node] node
      # @param [Symbol] meth
      # @param [Hash] opts
      # @return [String, nil]
      def handle_map_block(node, meth, **opts)
        return nil unless %i[map collect].include?(meth)

        inner = run_last_expr_type(node.children[2], **opts)
        return nil unless inner && inner != 'Object' && inner != 'untyped'

        "Array<#{inner}>"
      end

      # @note module_function: defines #block_send_rbs_type (visibility: private)
      # @param [Parser::AST::Node] node
      # @param [Parser::AST::Node] send_node
      # @param [Hash] opts
      # @return [String, nil]
      def block_send_rbs_type(node, send_node, **opts)
        rbs_type = send_rbs_type(send_node.children[0], send_node.children[1], **opts)
        return nil unless rbs_type

        block_rbs_with_inner(rbs_type, node.children[2], **opts) || rbs_type
      end

      # @note module_function: defines #block_rbs_with_inner (visibility: private)
      # @param [String, nil] rbs_type
      # @param [Parser::AST::Node] block_body
      # @param [Hash] opts
      # @return [String, nil]
      def block_rbs_with_inner(rbs_type, block_body, **opts)
        inner = run_last_expr_type(block_body, **opts)
        return nil unless inner

        substituted = block_generic_substitution(rbs_type, inner)
        return substituted if substituted

        bare_container_type(rbs_type, inner)
      end

      # @note module_function: defines #block_generic_substitution (visibility: private)
      # @param [String, nil] rbs_type
      # @param [String] inner
      # @return [String, nil]
      def block_generic_substitution(rbs_type, inner)
        return nil unless generic_placeholder?(rbs_type)

        inner_generic = extract_generic_inner(rbs_type)
        return nil unless inner_generic

        placeholders = placeholder_tokens(inner_generic)
        result = substitute_placeholders(rbs_type, placeholders, inner)
        return result unless result == rbs_type

        fallback_generic_substitution(rbs_type, inner)
      end

      # @note module_function: defines #placeholder_tokens (visibility: private)
      # @param [String] inner_generic
      # @return [Array<String>]
      def placeholder_tokens(inner_generic)
        split_generic_args(inner_generic).select do |arg|
          placeholder_token?(arg.strip.delete_suffix('?').strip)
        end
      end

      # @note module_function: defines #substitute_placeholders (visibility: private)
      # @param [String] rbs_type
      # @param [Array<String>] placeholders
      # @param [String] inner
      # @return [String]
      def substitute_placeholders(rbs_type, placeholders, inner)
        result = rbs_type.dup
        placeholders.each do |ph|
          token = ph.strip.delete_suffix('?').strip
          result = result.gsub(token, inner)
        end
        result
      end

      # @note module_function: defines #fallback_generic_substitution (visibility: private)
      # @param [String] rbs_type
      # @param [String] inner
      # @return [String]
      def fallback_generic_substitution(rbs_type, inner)
        rbs_type.gsub(/\bU\b/, inner).gsub(/\bElem\b/, inner).gsub(/\buntyped\b/, inner)
                .gsub(/\bV\b/, inner).gsub(/\bT\b/, inner).gsub(/\bE\b/, inner).gsub(/\bK\b/, inner)
      end

      # @note module_function: defines #bare_container_type (visibility: private)
      # @param [String, nil] rbs_type
      # @param [String] inner
      # @return [String, nil]
      def bare_container_type(rbs_type, inner)
        base = rbs_type.split(/[<\[ ]/).first
        return nil unless %w[Array Set Enumerable Enumerator].include?(base)
        return nil if rbs_type.include?('<') || rbs_type.include?('[')

        "#{base}<#{inner}>"
      end

      # @note module_function: defines #generic_placeholder? (visibility: private)
      # @param [String, nil] rbs_type
      # @return [Boolean]
      def generic_placeholder?(rbs_type)
        return false unless rbs_type =~ /[<\[]/

        inner = extract_generic_inner(rbs_type)
        return false unless inner

        split_generic_args(inner).any? do |arg|
          placeholder_token?(arg.strip.delete_suffix('?').strip)
        end
      end

      # @note module_function: defines #placeholder_token? (visibility: private)
      # @param [String] token
      # @return [Boolean]
      def placeholder_token?(token)
        token == 'untyped' || token.include?('::') || token =~ /\A[a-z]/ ||
          (token =~ /\A[A-Z][A-Za-z0-9_]*\z/ && !Docscribe::Types::Primitive.primitive?(token))
      end

      # Handle `:send` node for last_expr_type.
      #
      # @note module_function: defines #handle_send_node (visibility: private)
      # @param [Parser::AST::Node] node the `:return` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_send_node(node, **opts)
        recv = node.children[0]
        meth = node.children[1]
        rbs = send_rbs_type(recv, meth, **opts) if opts[:core_rbs_provider]
        return rbs if rbs

        compound = infer_from_compound_assign(node, **opts)
        return compound if compound

        str = string_send_type(meth, recv)
        return str if str

        Literals.type_from_literal(node, fallback_type: opts[:fallback_type])
      end

      # @note module_function: defines #string_send_type (visibility: private)
      # @param [Symbol] meth
      # @param [Parser::AST::Node, nil] recv
      # @return [String, nil]
      def string_send_type(meth, recv)
        return 'String' if string_like_method?(meth)
        return 'String' if file_join_method?(meth, recv)
        return 'String' if sub_string_method?(meth, recv)

        nil
      end

      # @note module_function: defines #string_like_method? (visibility: private)
      # @param [Symbol] meth
      # @return [Boolean]
      def string_like_method?(meth)
        %i[to_s to_str inspect].include?(meth)
      end

      # @note module_function: defines #file_join_method? (visibility: private)
      # @param [Symbol] meth
      # @param [Parser::AST::Node, nil] recv
      # @return [Boolean]
      def file_join_method?(meth, recv)
        meth == :join && recv&.type == :const && recv.children[1] == :File
      end

      # @note module_function: defines #sub_string_method? (visibility: private)
      # @param [Symbol] meth
      # @param [Parser::AST::Node, nil] recv
      # @return [Boolean]
      def sub_string_method?(meth, recv)
        meth == :sub && recv && recv.type != :const
      end

      # @note module_function: defines #handle_csend_node (visibility: private)
      # @param [Parser::AST::Node] node the `:csend` AST node (safe navigation)
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_csend_node(node, **opts)
        recv = node.children[0]
        meth = node.children[1]
        rbs_type = send_rbs_type(recv, meth, **opts) if opts[:core_rbs_provider] || opts[:signature_provider]
        if rbs_type
          unify_types(rbs_type, 'nil', fallback_type: opts[:fallback_type] || FALLBACK_TYPE,
                                       nil_as_optional: opts.fetch(:nil_as_optional, true))
        else
          opts[:fallback_type] || FALLBACK_TYPE
        end
      end

      # Resolve RBS return type for a send node, trying explicit receiver first,
      # then falling back to the method's container for implicit self calls.
      #
      # @note module_function: defines #send_rbs_type (visibility: private)
      # @param [Parser::AST::Node, nil] recv the receiver node
      # @param [Symbol] meth the method name
      # @param [Hash] opts additional keyword options
      # @return [String, nil]
      def send_rbs_type(recv, meth, **opts)
        rbs_type = resolve_rbs_for_send(recv, meth, opts[:core_rbs_provider], opts[:local_var_types],
                                        opts[:param_types])
        return rbs_type if rbs_type

        rbs_type = resolve_rbs_for_send_with_signature_provider(recv, meth, **opts)
        return rbs_type if rbs_type

        container_rbs_return_type(meth, **opts) if recv.nil?
      end

      # Resolve RBS return type for a send node's receiver, if possible.
      #
      # Handles `:lvar`, chained `:send`, literal (`:int`, `:str`, etc.),
      # and variable (`:ivar`, `:gvar`, `:cvar`) receivers.
      #
      # @note module_function: defines #resolve_rbs_for_send (visibility: private)
      # @param [Parser::AST::Node, nil] recv the receiver node of the send
      # @param [Symbol] meth the method name being called
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider optional RBS provider for core type lookup
      # @param [Hash<String, String>?] local_var_types inferred local variable type map
      # @param [Hash<String, String>?] param_types parameter name to type map
      # @return [String, nil] resolved type or nil if unresolvable
      def resolve_rbs_for_send(recv, meth, core_rbs_provider, local_var_types, param_types)
        recv_type = receiver_rbs_type_name(recv, core_rbs_provider, local_var_types, param_types)
        return nil unless recv_type

        if core_rbs_provider
          rbs = resolve_rbs_return_type(recv_type, meth, core_rbs_provider)
          return substitute_rbs_type(rbs, recv_type) unless rbs == FALLBACK_TYPE
        end

        nil
      end

      # Resolve RBS return type via signature_provider fallback.
      #
      # Tries project-level RBS when core_rbs_provider fails.
      #
      # @note module_function: defines #resolve_rbs_for_send_with_signature_provider (visibility: private)
      # @param [Parser::AST::Node, nil] recv the receiver node
      # @param [Symbol] meth the method name
      # @param [Hash] opts additional keyword options
      # @return [String, nil]
      def resolve_rbs_for_send_with_signature_provider(recv, meth, **opts)
        return nil unless opts[:signature_provider]

        recv_type = receiver_rbs_type_name(recv, opts[:core_rbs_provider], opts[:local_var_types],
                                           opts[:param_types])
        return nil unless recv_type

        rbs = opts[:signature_provider].signature_for(container: recv_type, scope: :instance, name: meth)&.return_type
        rbs ? substitute_rbs_type(rbs, recv_type) : nil
      end

      # Resolve return type from the current method's container via RBS.
      #
      # Handles implicit self calls (recv is nil) by looking up the method
      # on the container class.
      #
      # @note module_function: defines #container_rbs_return_type (visibility: private)
      # @param [Symbol] meth the method name being called
      # @param [Hash] opts additional keyword options (must include :container and :core_rbs_provider)
      # @return [String, nil] resolved type or nil if unresolvable
      def container_rbs_return_type(meth, **opts)
        return unless opts[:container]

        if opts[:core_rbs_provider]
          rbs = resolve_rbs_return_type(opts[:container], meth, opts[:core_rbs_provider])
          return substitute_rbs_type(rbs, opts[:container]) unless rbs == FALLBACK_TYPE
        end

        if opts[:signature_provider]
          sig = opts[:signature_provider].signature_for(container: opts[:container], scope: :instance, name: meth)
          return substitute_rbs_type(sig.return_type, opts[:container]) if sig
        end

        nil
      end

      # Map a receiver AST node to its RBS type name string.
      #
      # Supports local variables, method calls, literals, and instance/global/class variables.
      #
      # @note module_function: when included, also defines #receiver_rbs_type_name (instance visibility: private)
      # @param [Parser::AST::Node, nil] recv the receiver node
      # @param [Object, nil] core_rbs_provider core RBS provider
      # @param [Hash<Object, Object>, nil] local_var_types inferred local variable types
      # @param [Hash<String, String>, nil] param_types parameter name to type map
      # @return [String, nil]
      LITERAL_RBS_TYPES = {
        int: 'Integer', str: 'String', sym: 'Symbol', true: 'Boolean',
        false: 'Boolean', float: 'Float', array: 'Array', hash: 'Hash',
        nil: 'NilClass'
      }.freeze

      # Infer return type from a compound-assignment-like `:send`.
      #
      # RBS -> Infer: no hardcoded operator list, always try left/right via Infer,
      # then RBS for meth on receiver, else unify with String? handling.
      #
      # @note module_function: defines #infer_from_compound_assign (visibility: private)
      # @param [Parser::AST::Node] node the `:send` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def infer_from_compound_assign(node, **opts)
        meth = node.children[1]
        recv = node.children[0]
        arg = node.children[2]
        left = compound_left_type(recv, **opts)
        right = compound_right_type(arg, **opts)
        rbs = compound_rbs_type(recv, left, meth, **opts)
        return rbs if rbs

        compound_fallback_type(left, right, meth, **opts)
      end

      # @note module_function: defines #compound_left_type (visibility: private)
      # @param [Parser::AST::Node, nil] recv
      # @param [Hash] opts
      # @return [String, nil]
      def compound_left_type(recv, **opts)
        return nil unless recv

        found = compound_var_lookup(recv, **opts)
        return found if found

        run_last_expr_type(recv, **compound_expr_opts(**opts))
      end

      # @note module_function: defines #compound_var_lookup (visibility: private)
      # @param [Parser::AST::Node] recv
      # @param [Hash] opts
      # @return [String, nil]
      def compound_var_lookup(recv, **opts)
        return nil unless %i[lvar ivar gvar cvar].include?(recv.type)

        name = recv.children[0].to_s
        if recv.type == :lvar
          lookup_lvar_type(name, opts[:local_var_types], opts[:param_types])
        else
          opts[:local_var_types]&.fetch(name, nil)
        end
      end

      # @note module_function: defines #compound_right_type (visibility: private)
      # @param [Parser::AST::Node, nil] arg
      # @param [Hash] opts
      # @return [String, nil]
      def compound_right_type(arg, **opts)
        return nil unless arg

        run_last_expr_type(arg, **compound_expr_opts(**opts))
      end

      # @note module_function: defines #compound_expr_opts (visibility: private)
      # @param [Hash] opts
      # @return [Hash<Symbol, Object>]
      def compound_expr_opts(**opts)
        {
          fallback_type: opts[:fallback_type] || FALLBACK_TYPE,
          nil_as_optional: true,
          local_var_types: opts[:local_var_types],
          param_types: opts[:param_types],
          core_rbs_provider: opts[:core_rbs_provider],
          signature_provider: opts[:signature_provider],
          container: opts[:container]
        }
      end

      # @note module_function: defines #compound_rbs_type (visibility: private)
      # @param [Parser::AST::Node, nil] recv
      # @param [String, nil] left
      # @param [Symbol] meth
      # @param [Hash] opts
      # @return [String, nil]
      def compound_rbs_type(recv, left, meth, **opts)
        recv_type = cleaned_recv_type(left) ||
                    receiver_rbs_type_name(recv, opts[:core_rbs_provider],
                                           opts[:local_var_types], opts[:param_types])
        return nil unless recv_type && meth

        resolve_compound_rbs(recv_type, meth, **opts)
      end

      # @note module_function: defines #resolve_compound_rbs (visibility: private)
      # @param [String] recv_type
      # @param [Symbol] meth
      # @param [Hash] opts
      # @return [String, nil]
      def resolve_compound_rbs(recv_type, meth, **opts)
        if opts[:core_rbs_provider]
          rbs = resolve_rbs_return_type(recv_type, meth, opts[:core_rbs_provider])
          return substitute_rbs_type(rbs, recv_type) unless rbs == FALLBACK_TYPE
        end
        if opts[:signature_provider]
          sig = opts[:signature_provider].signature_for(container: recv_type, scope: :instance, name: meth)
          return substitute_rbs_type(sig.return_type, recv_type) if sig
        end
        nil
      end

      # @note module_function: defines #compound_fallback_type (visibility: private)
      # @param [String, nil] left
      # @param [String, nil] right
      # @param [Symbol] meth
      # @param [Hash] opts
      # @return [String, nil]
      def compound_fallback_type(left, right, meth, **opts)
        fallback = (opts[:fallback_type] || FALLBACK_TYPE).to_s
        return synthesize_shovel_type(left, right, fallback: fallback) if shovel_method?(left, meth, opts[:core_rbs_provider])
        return nil unless %i[+ - * / % ** | & ^].include?(meth)

        fallback_concrete_type(left, right, fallback) ||
          unify_types(left, right, fallback_type: fallback, nil_as_optional: true)
      end

      # @note module_function: defines #fallback_concrete_type (visibility: private)
      # @param [String, nil] left
      # @param [String, nil] right
      # @param [String] fallback
      # @return [String, nil]
      def fallback_concrete_type(left, right, fallback)
        left_is_fallback = fallback_type?(left, fallback)
        right_is_fallback = fallback_type?(right, fallback)
        preferred = fallback_preferred_side(left, right, left_is_fallback, right_is_fallback)
        return preferred if preferred
        return fallback if left_is_fallback && right_is_fallback

        nil
      end

      # @note module_function: defines #fallback_preferred_side (visibility: private)
      # @param [String, nil] left
      # @param [String, nil] right
      # @param [Boolean] left_is_fallback
      # @param [Boolean] right_is_fallback
      # @return [String, nil]
      def fallback_preferred_side(left, right, left_is_fallback, right_is_fallback)
        return right.to_s if left_is_fallback && !right_is_fallback && right
        return left.to_s if right_is_fallback && !left_is_fallback && left

        nil
      end

      # @note module_function: defines #fallback_type? (visibility: private)
      # @param [String, nil] type
      # @param [String] fallback
      # @return [Boolean]
      def fallback_type?(type, fallback)
        type.nil? || fallback_alias?(type, fallback)
      end

      # @note module_function: defines #cleaned_recv_type (visibility: private)
      # @param [String, nil] raw
      # @return [String, nil]
      def cleaned_recv_type(raw) # rubocop:disable SortedMethodsByCall/Waterfall
        return nil unless raw && raw != FALLBACK_TYPE

        str = raw.to_s.strip
        return nil if str.empty?

        str = stripped_union_type(str) || str if str.include?(',')
        cleaned = str.delete_suffix('?').strip
        cleaned.empty? ? nil : cleaned
      end # rubocop:enable SortedMethodsByCall/Waterfall

      # @note module_function: defines #synthesize_shovel_type (visibility: private)
      # @param [String, nil] left
      # @param [String, nil] right
      # @param [String] fallback
      # @return [String]
      def synthesize_shovel_type(left, right, fallback:)
        l = left || fallback
        r = right || fallback
        base = l.split(/[<\[ ]/).first.to_s.strip.delete_suffix('?')
        return shovel_array_type(l, r, base, fallback) if %w[Array Set Enumerable Enumerator].include?(base)

        l
      end

      # Whether left#meth is shovel (returns self) via RBS dynamically, not hardcoding :<<.
      #
      # @note module_function: defines #shovel_method? (visibility: private)
      # @param [String, nil] left left type
      # @param [Symbol] meth method name
      # @param [Docscribe::Types::RBS::Provider?] provider optional RBS provider
      # @return [Boolean] true if shovel
      def shovel_method?(left, meth, provider)
        return false unless left && meth

        base = left.split(/[<\[ ]/).first.to_s.strip.delete_suffix('?')
        return false if base.empty?
        return true if resolve_self_via_rbs?(base, meth, provider)

        resolve_self_via_rbs?(base, meth, core_rbs_provider)
      end

      # @note module_function: defines #resolve_self_via_rbs? (visibility: private)
      # @param [String] base
      # @param [Symbol] meth
      # @param [Docscribe::Types::RBS::Provider?] provider
      # @return [Boolean]
      def resolve_self_via_rbs?(base, meth, provider)
        return false unless provider

        resolve_rbs_return_type(base, meth, provider) == 'self'
      end

      # Core RBS provider singleton for shovel/primitive checks (dynamic, not hardcoding).
      #
      # @note module_function: defines #core_rbs_provider (visibility: private)
      # @raise [LoadError]
      # @raise [StandardError]
      # @return [Docscribe::Types::RBS::Provider, nil]
      def core_rbs_provider
        @core_rbs_provider ||= begin
          require_relative '../types/rbs/provider'
          Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
        rescue LoadError, StandardError
          nil
        end
      end

      # @note module_function: defines #shovel_array_type (visibility: private)
      # @param [String] left_str
      # @param [String] right_str
      # @param [String] base
      # @param [String] fallback
      # @return [String]
      def shovel_array_type(left_str, right_str, base, fallback)
        return left_str if shovel_left_generic?(left_str)
        return left_str if shovel_right_invalid?(right_str, fallback)

        cleaned = right_str.to_s.strip.delete_suffix('?').strip
        return left_str if cleaned == 'nil' || cleaned.empty? || cleaned == FALLBACK_TYPE

        "#{base}<#{cleaned}>"
      end

      # @note module_function: defines #shovel_left_generic? (visibility: private)
      # @param [String] str
      # @return [Boolean]
      def shovel_left_generic?(str)
        str.include?('<') || str.include?('[')
      end

      # @note module_function: defines #shovel_right_invalid? (visibility: private)
      # @param [String] str
      # @param [String] fallback
      # @return [Boolean]
      def shovel_right_invalid?(str, fallback)
        str == fallback || %w[Object untyped].include?(str)
      end

      # Map receiver AST node to RBS type name.
      #
      # @note module_function: defines #receiver_rbs_type_name (visibility: private)
      # @param [Parser::AST::Node, nil] recv the receiver AST node
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider core RBS type provider
      # @param [Hash<String, String>?] local_var_types inferred local variable types
      # @param [Hash<String, String>?] param_types parameter name-to-type map
      # @return [String, nil]
      def receiver_rbs_type_name(recv, core_rbs_provider, local_var_types, param_types)
        return unless recv

        literal = receiver_literal_type(recv)
        return literal if literal
        return receiver_var_type(recv, local_var_types, param_types) if var_receiver?(recv)

        receiver_dispatch_type(recv, core_rbs_provider, local_var_types, param_types)
      end

      # @note module_function: defines #receiver_dispatch_type (visibility: private)
      # @param [Parser::AST::Node] recv
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider
      # @param [Hash<String, String>?] local_var_types
      # @param [Hash<String, String>?] param_types
      # @return [String, nil]
      def receiver_dispatch_type(recv, core_rbs_provider, local_var_types, param_types)
        case recv.type
        when :send, :csend
          receiver_send_type(recv, core_rbs_provider, local_var_types, param_types)
        when :or, :and
          receiver_or_and_type(recv, core_rbs_provider, local_var_types, param_types)
        when :begin
          receiver_begin_type(recv, core_rbs_provider, local_var_types, param_types)
        end
      end

      # @note module_function: defines #receiver_begin_type (visibility: private)
      # @param [Parser::AST::Node] recv
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider
      # @param [Hash<String, String>?] local_var_types
      # @param [Hash<String, String>?] param_types
      # @return [String, nil]
      def receiver_begin_type(recv, core_rbs_provider, local_var_types, param_types)
        inner = recv.children[0]
        return unless inner && recv.children.size == 1

        receiver_rbs_type_name(inner, core_rbs_provider, local_var_types, param_types)
      end

      # @note module_function: defines #receiver_or_and_type (visibility: private)
      # @param [Parser::AST::Node, nil] recv
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider
      # @param [Hash<String, String>?] local_var_types
      # @param [Hash<String, String>?] param_types
      # @return [String, nil]
      def receiver_or_and_type(recv, core_rbs_provider, local_var_types, param_types)
        left = receiver_rbs_type_name(recv.children[0], core_rbs_provider, local_var_types, param_types)
        right = receiver_rbs_type_name(recv.children[1], core_rbs_provider, local_var_types, param_types)
        left_clean = resolve_cleaned_type(left)
        right_clean = resolve_cleaned_type(right)
        receiver_or_and_preference(left_clean, right_clean, left, right)
      end

      # @note module_function: defines #resolve_cleaned_type (visibility: private)
      # @param [String, nil] type
      # @return [String, nil]
      def resolve_cleaned_type(type)
        return nil unless type

        cleaned_recv_type(type) || type
      end

      # @note module_function: defines #receiver_or_and_preference (visibility: private)
      # @param [String, nil] left_clean
      # @param [String, nil] right_clean
      # @param [String, nil] left
      # @param [String, nil] right
      # @return [String, nil]
      def receiver_or_and_preference(left_clean, right_clean, left, right)
        preferred = single_clean_preference(left_clean, right_clean)
        return preferred if preferred
        return left_clean if both_clean_equal?(left_clean, right_clean)

        left_clean || right_clean || left || right
      end

      # @note module_function: defines #single_clean_preference (visibility: private)
      # @param [String, nil] left_clean
      # @param [String, nil] right_clean
      # @return [String, nil]
      def single_clean_preference(left_clean, right_clean)
        return left_clean if left_clean && !right_clean
        return right_clean if right_clean && !left_clean

        nil
      end

      # @note module_function: defines #both_clean_equal? (visibility: private)
      # @param [String, nil] left_clean
      # @param [String, nil] right_clean
      # @return [Boolean]
      def both_clean_equal?(left_clean, right_clean)
        left_clean && right_clean && left_clean == right_clean
      end

      # @note module_function: defines #receiver_literal_type (visibility: private)
      # @param [Parser::AST::Node, nil] recv
      # @return [String, nil]
      def receiver_literal_type(recv)
        LITERAL_RBS_TYPES[recv.type] if LITERAL_RBS_TYPES.key?(recv.type)
      end

      # @note module_function: defines #var_receiver? (visibility: private)
      # @param [Parser::AST::Node, nil] recv
      # @return [Boolean]
      def var_receiver?(recv)
        %i[lvar ivar gvar cvar].include?(recv.type)
      end

      # @note module_function: defines #receiver_var_type (visibility: private)
      # @param [Parser::AST::Node, nil] recv
      # @param [Hash<String, String>?] local_var_types
      # @param [Hash<String, String>?] param_types
      # @return [String, nil]
      def receiver_var_type(recv, local_var_types, param_types)
        raw = lookup_lvar_type(recv.children.first, local_var_types, param_types)
        return nil unless raw

        cleaned = raw.include?(',') ? stripped_union_type(raw) : raw
        cleaned = cleaned.to_s.strip.delete_suffix('?').strip
        return nil if cleaned.empty? || cleaned == 'FALLBACK_TYPE'

        cleaned
      end

      # @note module_function: defines #stripped_union_type (visibility: private)
      # @param [String, nil] raw
      # @return [String, nil]
      def stripped_union_type(raw)
        parts = split_top_level_commas(raw).map { |p| p.strip.delete_suffix('?').strip }
        non_nil = parts.reject { |p| %w[nil FALLBACK_TYPE].include?(p) }
        (non_nil.first || parts.first).to_s.strip.delete_suffix('?').strip
      end

      # Split a type string by top-level commas (outside any < > [ ] ( ) nesting).
      #
      # Used to distinguish union types (`String, nil`) from generic commas (`Hash<Integer, String>`).
      #
      # @note module_function: defines #split_top_level_commas (visibility: private)
      # @param [String] str the type string to split
      # @return [Array<String>]
      def split_top_level_commas(str)
        state = { parts: [], cur: +'', da: 0, db: 0, dp: 0 } #: Hash[Symbol, untyped]
        str.each_char { |chr| split_process_char(chr, state, strip: false) }
        state[:parts] << state[:cur] unless state[:cur].empty?
        state[:parts]
      end

      # @note module_function: defines #receiver_send_type (visibility: private)
      # @param [Parser::AST::Node, nil] recv
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider
      # @param [Hash<String, String>?] local_var_types
      # @param [Hash<String, String>?] param_types
      # @return [String, nil]
      def receiver_send_type(recv, core_rbs_provider, local_var_types, param_types)
        run_last_expr_type(recv, fallback_type: FALLBACK_TYPE, nil_as_optional: false,
                                 core_rbs_provider: core_rbs_provider, param_types: param_types,
                                 local_var_types: local_var_types)
      end

      # Safely get a type string from a literal node, returning nil if the node
      # is not a literal or yields no type.
      #
      # @note module_function: defines #type_from_literal_safe (visibility: private)
      # @param [Parser::AST::Node, nil] node literal AST node
      # @return [String, nil]
      def type_from_literal_safe(node)
        return nil unless node

        t = Literals.type_from_literal(node, fallback_type: FALLBACK_TYPE)
        t unless t == FALLBACK_TYPE
      end

      # Resolve RBS return type for an `:lvar` receiver.
      #
      # @note module_function: defines #resolve_lvar_rbs (visibility: private)
      # @param [Parser::AST::Node?] recv the receiver node of the send
      # @param [Symbol] meth the method name being called
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider core RBS type lookup provider
      # @param [Hash<String, String>?] local_var_types pre-built local variable types map
      # @param [Hash<String, String>?] param_types parameter name -> type map for lvar resolution
      # @return [String, nil]
      def resolve_lvar_rbs(recv, meth, core_rbs_provider, local_var_types, param_types)
        lvar_name = recv&.children&.first
        recv_type = lookup_lvar_type(lvar_name, local_var_types, param_types)
        return nil unless recv_type

        rbs_type = resolve_rbs_return_type(recv_type, meth, core_rbs_provider)
        rbs_type unless rbs_type == FALLBACK_TYPE
      end

      # Look up a local variable's inferred type from local or parameter type maps.
      #
      # @note module_function: defines #lookup_lvar_type (visibility: private)
      # @param [String, Symbol, nil] lvar_name the local variable name
      # @param [Hash<String, String>?] local_var_types inferred local variable type map
      # @param [Hash<String, String>?] param_types parameter name to type map
      # @return [String, nil]
      def lookup_lvar_type(lvar_name, local_var_types, param_types)
        if local_var_types&.key?(lvar_name.to_s)
          val = local_var_types[lvar_name.to_s]
          return nil if val == FALLBACK_TYPE

          return val
        end
        return param_types[lvar_name.to_s] if param_types&.key?(lvar_name.to_s)

        nil
      end

      # Resolve RBS return type for a chained `:send` receiver.
      #
      # @note module_function: defines #resolve_chained_send_rbs (visibility: private)
      # @param [Parser::AST::Node?] recv the receiver node of the send
      # @param [Symbol] meth the method name being called
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider core RBS type lookup provider
      # @param [Hash<String, String>?] local_var_types pre-built local variable types map
      # @param [Hash<String, String>?] param_types parameter name -> type map for lvar resolution
      # @return [String, nil]
      def resolve_chained_send_rbs(recv, meth, core_rbs_provider, local_var_types, param_types)
        inner_type = run_last_expr_type(recv, fallback_type: nil, nil_as_optional: false,
                                              core_rbs_provider: core_rbs_provider, param_types: param_types,
                                              local_var_types: local_var_types)
        return nil unless inner_type

        rbs_type = resolve_rbs_return_type(inner_type, meth, core_rbs_provider)
        rbs_type unless rbs_type == FALLBACK_TYPE
      end

      # Infer the type of the last expression in a node.
      #
      # Supports:
      # - `begin` groups
      # - `if` branches
      # - `case` expressions
      # - explicit `return`
      # - literal-like expressions via {Literals.type_from_literal}
      # - method calls with RBS core type lookup
      #
      # @note module_function: defines #last_expr_type (visibility: private)
      # @param [Parser::AST::Node, nil] node expression node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def last_expr_type(node, **opts)
        run_last_expr_type(node, **opts)
      end

      # Dispatch `last_expr_type` based on node type.
      #
      # @note module_function: defines #run_last_expr_type (visibility: private)
      # @param [Parser::AST::Node, nil] node the `:return` AST node
      # @param [Hash] opts options passed through as keyword args
      # @return [String, nil]
      def run_last_expr_type(node, **opts)
        return unless node

        type = node.type == :defined? ? :defined : node.type
        method_name = :"handle_#{type}_node"
        if respond_to?(method_name, true)
          send(method_name, node, **opts)
        else
          Literals.type_from_literal(node, fallback_type: opts[:fallback_type])
        end
      end

      # Extract the return type from an explicit `:return` node.
      #
      # @note module_function: defines #handle_return_node (visibility: private)
      # @param [Parser::AST::Node] node the `:return` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_return_node(node, **opts)
        Literals.type_from_literal(node.children.first, fallback_type: opts[:fallback_type])
      end

      # @note module_function: defines #handle_const_node (visibility: private)
      # @param [Parser::AST::Node] node the `:const` AST node
      # @param [Hash] opts additional keyword options forwarded to type inference
      # @return [String, nil]
      def handle_const_node(node, **opts)
        fallback = (opts[:fallback_type] || FALLBACK_TYPE).to_s #: String
        resolved = Literals.type_from_literal(node, fallback_type: fallback)
        return fallback if fallback_alias?(resolved, fallback)

        const_name = node.children.last.to_s #: String
        return fallback if fallback_alias?(const_name, fallback)

        resolved
      end

      # Whether a type string is the fallback alias (FALLBACK_TYPE or the configured fallback type).
      #
      # @note module_function: defines #fallback_alias? (visibility: private)
      # @param [String, nil] type_str the type string to check
      # @param [String] fallback_type the configured fallback type
      # @return [Boolean]
      def fallback_alias?(type_str, fallback_type)
        return false if type_str.nil?

        s = type_str.to_s.strip.delete_suffix('?').strip
        s == fallback_type || s == 'FALLBACK_TYPE' || (fallback_type == 'Object' && s == 'untyped')
      end

      # Resolve an RBS return type for a method call.
      #
      # @note module_function: defines #resolve_rbs_return_type (visibility: private)
      # @param [String] container_type class or module name
      # @param [String, Symbol] method_name method name
      # @param [Docscribe::Types::RBS::Provider?] core_rbs_provider core RBS type lookup provider
      # @return [String] inferred return type
      def resolve_rbs_return_type(container_type, method_name, core_rbs_provider)
        return FALLBACK_TYPE unless core_rbs_provider

        sig = core_rbs_provider.signature_for(
          container: container_type,
          scope: :instance,
          name: method_name
        )

        sig&.return_type || FALLBACK_TYPE
      end

      # Substitute `self` and generic type variables in an RBS return type with the concrete receiver type.
      #
      # Handles `Array#<<` (`self` -> `Array<Elem>`) and `Hash#[]` (`V` -> value type).
      # For `self` returns the concrete receiver type; for `K`/`V`/`Elem` substitutes from generic args.
      #
      # @note module_function: defines #substitute_rbs_type (visibility: private)
      # @param [String] rbs the raw RBS return type string
      # @param [String] recv_type the concrete receiver type string
      # @return [String]
      def substitute_rbs_type(rbs, recv_type)
        self_sub = substitute_self_type(rbs, recv_type)
        return self_sub if self_sub

        inner = extract_generic_inner(recv_type)
        return rbs unless inner

        args = split_generic_args(inner)
        return rbs if args.empty?

        substitute_with_mapping(rbs, recv_type, args)
      end

      # @note module_function: defines #substitute_self_type (visibility: private)
      # @param [String] rbs
      # @param [String] recv_type
      # @return [String, nil]
      def substitute_self_type(rbs, recv_type)
        return recv_type if rbs == 'self'
        return "#{recv_type}?" if rbs == 'self?'

        nil
      end

      # @note module_function: defines #substitute_with_mapping (visibility: private)
      # @param [String] rbs
      # @param [String] recv_type
      # @param [Array<String>] args
      # @return [String]
      def substitute_with_mapping(rbs, recv_type, args)
        mapping = build_generic_mapping(recv_type, args)
        return rbs if mapping.empty?

        apply_generic_mapping(rbs, mapping, recv_type)
      end

      # @note module_function: defines #build_generic_mapping (visibility: private)
      # @param [String] recv_type
      # @param [Array<String>] args
      # @return [Hash<String, String>]
      def build_generic_mapping(recv_type, args)
        base = recv_type.split(/[<\[ ]/).first.to_s.strip
        mapping = {} #: Hash[String, String]
        fill_mapping_for_base(mapping, base, args)
        mapping
      end

      # @note module_function: defines #fill_mapping_for_base (visibility: private)
      # @param [Hash<String, String>] mapping
      # @param [String] base
      # @param [Array<String>] args
      # @return [void]
      def fill_mapping_for_base(mapping, base, args)
        case base
        when 'Hash' then fill_hash_mapping(mapping, args)
        when 'Array', 'Set', 'Enumerable', 'Enumerator' then fill_array_mapping(mapping, args)
        else fill_other_mapping(mapping, args)
        end
      end

      # @note module_function: defines #fill_hash_mapping (visibility: private)
      # @param [Hash<String, String>] mapping
      # @param [Array<String>] args
      # @return [void]
      def fill_hash_mapping(mapping, args)
        mapping['K'] = args[0] if args[0]
        mapping['V'] = args[1] if args[1]
      end

      # @note module_function: defines #fill_array_mapping (visibility: private)
      # @param [Hash<String, String>] mapping
      # @param [Array<String>] args
      # @return [void]
      def fill_array_mapping(mapping, args)
        %w[Elem T U E].each { |key| mapping[key] = args[0] if args[0] }
      end

      # @note module_function: defines #fill_other_mapping (visibility: private)
      # @param [Hash<String, String>] mapping
      # @param [Array<String>] args
      # @return [void]
      def fill_other_mapping(mapping, args)
        %w[Elem T U].each { |key| mapping[key] = args[0] if args[0] }
      end

      # @note module_function: defines #apply_generic_mapping (visibility: private)
      # @param [String] rbs
      # @param [Hash<String, String>] mapping
      # @param [String] recv_type
      # @return [String]
      def apply_generic_mapping(rbs, mapping, recv_type)
        stripped = rbs.delete_suffix('?').strip
        optional = rbs.end_with?('?')
        return optional ? "#{mapping[stripped]}?" : mapping[stripped] if mapping.key?(stripped)

        new_rbs = rbs.dup
        mapping.each { |var, val| new_rbs = new_rbs.gsub(/\b#{Regexp.escape(var)}\b/, val) }
        new_rbs.include?('self') ? new_rbs.gsub(/\bself\b/, recv_type) : new_rbs
      end

      # Extract the inner generic args string from a receiver type like `Array<String>` or `Hash<Integer, String>`.
      #
      # @note module_function: defines #extract_generic_inner (visibility: private)
      # @param [String] type the concrete type string
      # @return [String, nil]
      def extract_generic_inner(type)
        return unless type =~ /\A(?:Array|Hash|Set|Enumerable)[<\[](.*)[>\]]\z/m || type =~ /\A[^<\[\]]+[<\[](.*)[>\]]\z/m

        Regexp.last_match(1)
      end

      # Split a generic inner string like `Integer, Array<(Integer, String)>` by top-level commas.
      #
      # Respects nesting of `< > [ ] ( )` so tuples are not split.
      #
      # @note module_function: defines #split_generic_args (visibility: private)
      # @param [String] inner the raw inner string
      # @return [Array<String>]
      def split_generic_args(inner)
        state = { parts: [], cur: +'', da: 0, db: 0, dp: 0 } #: Hash[Symbol, untyped]
        inner.each_char { |chr| split_process_char(chr, state, strip: true) }
        last = state[:cur].strip
        state[:parts] << last unless last.empty?
        state[:parts]
      end

      # @note module_function: defines #split_process_char (visibility: private)
      # @param [String] chr single character
      # @param [Hash<Symbol, Object>] state mutable split state
      # @param [Boolean] strip whether to strip parts on comma
      # @return [void]
      def split_process_char(chr, state, strip:)
        case chr
        when '<', '>', '[', ']', '(', ')'
          split_handle_bracket(chr, state)
        when ','
          split_handle_comma(state, strip: strip)
        else
          state[:cur] << chr
        end
      end

      # @note module_function: defines #split_handle_bracket (visibility: private)
      # @param [String] chr bracket character
      # @param [Hash<Symbol, Object>] state mutable split state
      # @return [void]
      def split_handle_bracket(chr, state)
        case chr
        when '<' then state[:da] += 1
        when '>' then state[:da] -= 1
        when '[' then state[:db] += 1
        when ']' then state[:db] -= 1
        when '(' then state[:dp] += 1
        when ')' then state[:dp] -= 1
        end
        state[:cur] << chr
      end

      # @note module_function: defines #split_handle_comma (visibility: private)
      # @param [Hash<Symbol, Object>] state mutable split state
      # @param [Boolean] strip whether to strip
      # @return [void]
      def split_handle_comma(state, strip:)
        if state[:da].zero? && state[:db].zero? && state[:dp].zero?
          part = strip ? state[:cur].strip : state[:cur]
          state[:parts] << part
          state[:cur] = +''
        else
          state[:cur] << ','
        end
      end

      # Unify two inferred types into a single type string.
      #
      # Rules:
      # - identical types remain unchanged
      # - `nil` unions may become optional types if enabled
      # - otherwise falls back conservatively to `fallback_type`
      #
      # @note module_function: defines #unify_types (visibility: private)
      # @param [String, nil] type_a first type to unify
      # @param [String, nil] type_b second type to unify
      # @param [String] fallback_type type used when neither is nil
      # @param [Boolean] nil_as_optional whether to render nil unions as optional types
      # @return [String]
      def unify_types(type_a, type_b, fallback_type:, nil_as_optional:)
        type_a = coalesce_type(type_a, fallback_type)
        type_b = coalesce_type(type_b, fallback_type)
        return type_a if type_a == type_b

        unify_nil_types(type_a, type_b, nil_as_optional: nil_as_optional)
      end

      # @note module_function: defines #coalesce_type (visibility: private)
      # @param [String, nil] type
      # @param [String] fallback_type
      # @return [String]
      def coalesce_type(type, fallback_type)
        normalized = type || fallback_type
        normalized = fallback_type if normalized == 'FALLBACK_TYPE'
        normalized = 'Object' if normalized == 'untyped' && fallback_type == 'Object'
        normalized
      end

      # Unify two types where one may be `nil`, producing optional or union type.
      #
      # @note module_function: defines #unify_nil_types (visibility: private)
      # @param [String] type_a first type string
      # @param [String] type_b second type string
      # @param [Boolean] nil_as_optional whether to render nil unions as optional types
      # @return [String]
      def unify_nil_types(type_a, type_b, nil_as_optional:)
        if type_a == 'nil' || type_b == 'nil'
          non_nil = (type_a == 'nil' ? type_b : type_a)
          return nil_as_optional ? "#{non_nil}?" : "#{non_nil}, nil"
        end

        "#{type_a}, #{type_b}"
      end
    end
  end
end

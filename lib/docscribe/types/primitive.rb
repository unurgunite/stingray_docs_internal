# frozen_string_literal: true

# NOTE: no top-level `require 'rbs'` here on purpose — the rbs gem is
# optional (excluded on old rubies via BUNDLE_WITHOUT). It is required
# lazily in `.load_rbs_core`, which falls back to a hardcoded list when
# the gem is unavailable.
#
# `set` is required eagerly: it is a default gem on all supported rubies
# and `load_core_primitives` cannot run without it.
require 'set'

module Docscribe
  module Types
    # Dynamic primitive type detection via RBS core + YARD.
    #
    # Replaces hardcoded %w[String Integer ...] lists in
    # Returns and GenericCompatibility with RBS environment inspection.
    module Primitive
      module_function

      # Whether token matches alias pattern (lowercase after :: or capitalized not in primitives)
      #
      # @note module_function: defines #alias_pattern? (visibility: private)
      # @param [String] token
      # @return [Boolean]
      def alias_pattern?(token)
        base = normalized_base(token)
        return true if base =~ /\A[a-z]/ || base.include?('::')
        return true if base =~ /\A[A-Z]\z/

        !!(base =~ /\A[A-Z][A-Za-z0-9_]*\z/ && !core_primitives.include?(base))
      end

      # Whether a type string is an alias (contains alias token inside generic)
      #
      # @note module_function: defines #alias_type? (visibility: private)
      # @param [String] type_str
      # @return [Boolean]
      def alias_type?(type_str)
        # Check if any comma-separated inner is alias
        # For "Array<Elem>" or "MyAlias" etc
        type_str.split(',').any? { |part| alias_token?(part.strip) }
      end

      # Whether token is an alias/generic placeholder (Elem, U, ParamTag, MyAlias)
      # vs primitive. Inverse of primitive?.
      #
      # @note module_function: defines #alias_token? (visibility: private)
      # @param [String] token single type token
      # @return [Boolean] true if alias
      def alias_token?(token)
        base = normalized_base(token)
        return false if primitive?(base)
        return true if base =~ /\A[a-z]/ || base.include?('::')
        return true if base =~ /\A[A-Z]\z/

        !!(base =~ /\A[A-Z][A-Za-z0-9_]*\z/ && !core_primitives.include?(base))
      end

      # Whether token is a primitive type (String, Integer, etc) vs alias (Elem, U, ParamTag).
      #
      # Uses RBS core class declarations + YARD pseudo types (Boolean, void, untyped)
      # to avoid hardcoding the full list. Falls back to a minimal list if RBS unavailable.
      #
      # @note module_function: defines #primitive? (visibility: private)
      # @param [String] token type token (e.g., "String", "Elem", "ParamTag", "untyped")
      # @return [Boolean] true if primitive, false if alias/generic placeholder
      def primitive?(token)
        base = normalized_base(token)
        return false if base.empty?
        return true if %w[untyped void nil].include?(base)
        # YARD pseudo types that are not real RBS classes but considered primitives
        return true if %w[Boolean void untyped nil].include?(base)

        core_primitives.include?(base)
      end

      # @note module_function: defines #normalized_base (visibility: private)
      # @param [String] token
      # @return [String]
      def normalized_base(token)
        token.split('<').first.split('[').first.strip.delete_suffix('?').strip
      end

      # All core primitive class/module names from RBS environment (String, Array, etc)
      # plus YARD primitives. Computed once and cached.
      #
      # @note module_function: defines #core_primitives (visibility: private)
      # @return [Array<String>] primitive names
      def core_primitives
        @core_primitives ||= load_core_primitives
      end

      # Load core primitives from RBS environment. Falls back to minimal hardcoded list
      # if RBS not available (e.g., in test env without rbs gem).
      #
      # @note module_function: defines #load_core_primitives (visibility: private)
      # @return [Array<String>]
      def load_core_primitives
        primitives = Set.new
        load_yard_primitives(primitives)
        load_rbs_core(primitives)
        merge_primitives(primitives)
        primitives.to_a
      end

      # @note module_function: defines #load_yard_primitives (visibility: private)
      # @param [Set<String>] primitives
      # @return [Set<String>]
      def load_yard_primitives(primitives)
        primitives.merge(%w[Boolean void untyped nil true false])
      end

      # @note module_function: defines #load_rbs_core (visibility: private)
      # @param [Set<String>] primitives
      # @raise [LoadError]
      # @raise [StandardError]
      # @return [Set<String>]
      # @return [Set<String>] if LoadError, StandardError
      def load_rbs_core(primitives)
        require 'rbs'
        loader = RBS::EnvironmentLoader.new
        env = RBS::Environment.new
        loader.load(env: env)
        populate_class_decls(env, primitives)
        populate_interface_decls(env, primitives)
      rescue LoadError, StandardError
        primitives.merge(%w[String Integer Float Numeric Symbol Array Hash Range Regexp Proc Method NilClass TrueClass FalseClass BasicObject Kernel Object Class Module IO File Dir Time Date Enumerator
                            Set Enumerable])
      end

      # @note module_function: defines #populate_class_decls (visibility: private)
      # @param [RBS::Environment] env
      # @param [Set<String>] primitives
      # @return [void]
      def populate_class_decls(env, primitives)
        return unless env.respond_to?(:class_decls)

        env.class_decls.each_key { |k| primitives.merge([k.to_s.split('::').last, k.to_s]) }
      end

      # @note module_function: defines #populate_interface_decls (visibility: private)
      # @param [RBS::Environment] env
      # @param [Set<String>] primitives
      # @return [void]
      def populate_interface_decls(env, primitives)
        return unless env.respond_to?(:interface_decls)

        env.interface_decls.each_key { |k| primitives << k.to_s.split('::').last }
      end

      # @note module_function: defines #merge_primitives (visibility: private)
      # @param [Set<String>] primitives
      # @return [Set<String>]
      def merge_primitives(primitives)
        primitives.merge(%w[String Integer Float Numeric Symbol Array Hash Range Regexp Proc Method NilClass TrueClass FalseClass BasicObject Kernel Object])
      end
    end
  end
end

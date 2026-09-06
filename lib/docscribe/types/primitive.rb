# frozen_string_literal: true

require 'rbs'

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
        base = token.split('<').first.split('[').first.strip.delete_suffix('?').strip
        return true if base =~ /\A[a-z]/ || base.include?('::')

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
        base = token.split('<').first.split('[').first.strip.delete_suffix('?').strip
        return false if primitive?(base)
        return true if base =~ /\A[a-z]/ || base.include?('::')

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
        base = token.split('<').first.split('[').first.strip.delete_suffix('?').strip
        return false if base.empty?
        return true if %w[untyped void nil].include?(base)
        # YARD pseudo types that are not real RBS classes but considered primitives
        return true if %w[Boolean void untyped nil].include?(base)

        core_primitives.include?(base)
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
      # @raise [LoadError]
      # @raise [StandardError]
      # @return [Array<String>]
      def load_core_primitives
        primitives = Set.new
        load_yard_primitives(primitives)
        load_rbs_core(primitives)
        merge_primitives(primitives)
        primitives.to_a
      end

      def load_yard_primitives(primitives)
        primitives.merge(%w[Boolean void untyped nil true false])
      end

      def load_rbs_core(primitives) # rubocop:disable Metrics/AbcSize
        loader = RBS::EnvironmentLoader.new
        env = RBS::Environment.new
        loader.load(env: env)
        env.class_decls.each_key { |k| primitives.merge([k.to_s.split('::').last, k.to_s]) } if env.respond_to?(:class_decls)
        env.interface_decls.each_key { |k| primitives << k.to_s.split('::').last } if env.respond_to?(:interface_decls)
      rescue LoadError, StandardError
        primitives.merge(%w[String Integer Float Numeric Symbol Array Hash Range Regexp Proc Method NilClass TrueClass FalseClass BasicObject Kernel Object Class Module IO File Dir Time Date Enumerator
                            Set Enumerable])
      end # rubocop:enable Metrics/AbcSize

      def merge_primitives(primitives)
        primitives.merge(%w[String Integer Float Numeric Symbol Array Hash Range Regexp Proc Method NilClass TrueClass FalseClass BasicObject Kernel Object])
      end
    end
  end
end

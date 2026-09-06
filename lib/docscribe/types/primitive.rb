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
      def load_core_primitives # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        primitives = Set.new
        # Add YARD/RBS pseudo primitives
        primitives.merge(%w[Boolean void untyped nil true false])
        # Try to load RBS core
        begin
          loader = RBS::EnvironmentLoader.new
          # Load core rbs (String, Integer, Array, Hash, etc)
          # RBS 3.x: loader.add(library: 'rbs') or loader.add(path: ...)
          # Use Environment to get class decls
          env = RBS::Environment.new
          loader.load(env: env)
          # env.class_decls is Hash[Symbol, Hash] or similar
          if env.respond_to?(:class_decls)
            env.class_decls.each_key do |type_name|
              primitives << type_name.to_s.split('::').last
              primitives << type_name.to_s
            end
          end
          # Also add interface decls (e.g., _Each)
          env.interface_decls.each_key { |k| primitives << k.to_s.split('::').last } if env.respond_to?(:interface_decls)
        rescue LoadError, StandardError
          # Fallback minimal list
          primitives.merge(%w[String Integer Float Numeric Symbol Array Hash Range Regexp Proc Method NilClass TrueClass FalseClass BasicObject Kernel Object Class Module IO File Dir Time Date Enumerator
                              Set Enumerable])
        end
        # Normalize: ensure common primitives are present even if RBS load partial
        primitives.merge(%w[String Integer Float Numeric Symbol Array Hash Range Regexp Proc Method NilClass TrueClass FalseClass BasicObject Kernel Object])
        primitives.to_a
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
    end
  end
end

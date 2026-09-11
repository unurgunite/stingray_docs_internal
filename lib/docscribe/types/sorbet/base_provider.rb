# frozen_string_literal: true

require 'docscribe/types/signature'
require 'docscribe/types/rbs/type_formatter'

module Docscribe
  module Types
    module Sorbet
      # Shared base for Sorbet-backed signature providers.
      #
      # This class parses Sorbet-style signatures through the RBS RBI prototype
      # API and indexes them into Docscribe's normalized signature model.
      #
      # Concrete subclasses decide where the Sorbet source comes from:
      # - SourceProvider => inline `sig` declarations in the current Ruby file
      # - RBIProvider    => project RBI files
      class BaseProvider
        # Initialize
        #
        # @param [Boolean] collapse_generics whether generic container details
        # @param [Boolean] collapse_object_generics collapse Object generics
        # @return [void]
        def initialize(collapse_generics: false, collapse_object_generics: false)
          require 'rbs'
          @collapse_generics = !!collapse_generics
          @collapse_object_generics = !!collapse_object_generics
          @index = {}
          @warned = false
        end

        # Look up a normalized method signature by container, scope, and name.
        #
        # @param [String] container e.g. "MyModule::MyClass"
        # @param [Symbol] scope :instance or :class
        # @param [Symbol, String] name method name
        # @return [Docscribe::Types::MethodSignature, nil]
        def signature_for(container:, scope:, name:)
          @index[[normalize_container(container), scope.to_sym, name.to_sym]]
        end

        private

        # Parse Sorbet-flavored Ruby/RBI source and index any signatures found.
        #
        # Parsing failures are treated as non-fatal so Docscribe can fall back to
        # other providers or plain inference.
        #
        # @private
        # @param [String] source source text to parse
        # @param [String] label file label used in debug warnings
        # @raise [LoadError]
        # @raise [::RBS::BaseError]
        # @raise [SyntaxError]
        # @raise [StandardError]
        # @return [void]
        # @return [nil] if LoadError
        # @return [nil] if ::RBS::BaseError, SyntaxError, StandardError
        def load_from_string(source, label:)
          return unless defined?(RubyVM::AbstractSyntaxTree)

          parser = ::RBS::Prototype::RBI.new
          parse(parser, source)
          index_decls(parser.decls)
        rescue LoadError
          nil
        rescue ::RBS::BaseError, SyntaxError, StandardError => e
          warn_once("Docscribe: Sorbet signature load failed for #{label}: #{e.class}: #{e.message}")
          nil
        end

        # Parse the source with the RBS RBI prototype, suppressing the parser's
        # "Unexpected type_node" STDERR noise unless DOCSCRIBE_RBS_DEBUG=1.
        #
        # @private
        # @param [::RBS::Prototype::RBI] parser RBI parser instance
        # @param [String] source source text to parse
        # @return [void]
        def parse(parser, source)
          if ENV['DOCSCRIBE_RBS_DEBUG'] == '1'
            parser.parse(source)
          else
            suppress_rbs_noise { parser.parse(source) }
          end
        end

        # Run the block with STDERR discarded. RBS's RBI prototype prints
        # "Unexpected type_node" directly to STDERR for constructs it doesn't
        # model (e.g. Herb-typed RBIs); the fallback to `Any` is already handled
        # by the parser, so the noise is safe to drop. `IO#reopen` needs a real
        # IO or path, so redirect to File::NULL rather than a StringIO.
        #
        # @private
        # @return [T] the block's return value
        def suppress_rbs_noise
          original_stderr = $stderr.dup
          $stderr.reopen(File::NULL, 'w')
          yield
        ensure
          $stderr.reopen(original_stderr)
          original_stderr.close
        end

        # Index parsed declarations into the provider lookup table.
        #
        # @private
        # @param [Array<Object>] decls parsed RBS declarations
        # @return [void]
        def index_decls(decls)
          Array(decls).each do |decl|
            next unless decl.respond_to?(:name)
            next unless decl.respond_to?(:members)

            container = normalize_container(decl.name.to_s)
            decl.members.each { |member| process_method_member(container, member) }
          end
        end

        # Process a single method definition member into the index.
        #
        # @private
        # @param [String] container normalized container name
        # @param [Object] member RBS method definition member
        # @return [void]
        def process_method_member(container, member)
          return unless method_definition_member?(member)

          scope = member.kind == :singleton ? :class : :instance
          overload = member.overloads&.first
          return unless overload

          func = overload.method_type.type #: ::RBS::Types::Function
          @index[[container, scope, member.name.to_s.to_sym]] = build_signature(func)
        end

        # Method definition member
        #
        # @private
        # @param [Object] member member to check for method def
        # @return [Boolean, nil]
        def method_definition_member?(member)
          defined?(::RBS::AST::Members::MethodDefinition) &&
            member.is_a?(::RBS::AST::Members::MethodDefinition)
        end

        # Convert an RBS function type into Docscribe's simplified signature model.
        #
        # @private
        # @param [RBS::Types::Function] func RBS function type to convert
        # @return [Docscribe::Types::MethodSignature]
        def build_signature(func)
          MethodSignature.new(
            return_type: format_type(func.return_type),
            param_types: build_param_types(func),
            rest_positional: build_rest_positional(func),
            rest_keywords: build_rest_keywords(func)
          )
        end

        # Build a name => type map for ordinary positional/keyword parameters.
        #
        # @private
        # @param [RBS::Types::Function] func RBS function to extract params
        # @return [Hash<String, String>]
        def build_param_types(func)
          param_types = {} #: Hash[String, String]

          add_positionals!(param_types, func.required_positionals)
          add_positionals!(param_types, func.optional_positionals)
          add_positionals!(param_types, func.trailing_positionals)

          add_keywords!(param_types, func.required_keywords)
          add_keywords!(param_types, func.optional_keywords)

          param_types
        end

        # Add keyword parameters to the normalized parameter map.
        #
        # @private
        # @param [Hash<String, String>] param_types normalized param type map
        # @param [Hash<Symbol, RBS::Types::Function::Param>] keywords keyword parameter entries
        # @return [void]
        def add_keywords!(param_types, keywords)
          keywords.each do |kw, p|
            param_types[kw.to_s] = format_type(p.type)
          end
        end

        # Add positional parameters with names to the normalized param map.
        #
        # @private
        # @param [Hash<String, String>] param_types normalized param type map
        # @param [Array<RBS::Types::Function::Param>] list positional parameter objects
        # @return [void]
        def add_positionals!(param_types, list)
          list.each do |p|
            next unless p.name

            param_types[p.name.to_s] = format_type(p.type)
          end
        end

        # Build normalized `*args` metadata.
        #
        # @private
        # @param [RBS::Types::Function] func RBS function for rest params
        # @return [Docscribe::Types::RestPositional, nil]
        def build_rest_positional(func)
          rp = func.rest_positionals
          return nil unless rp

          RestPositional.new(
            name: rp.name&.to_s,
            element_type: format_type(rp.type)
          )
        end

        # Build normalized `**kwargs` metadata.
        #
        # Sorbet keyword-rest signatures describe the value type. For generated
        # YARD output, we expose that as a Hash keyed by Symbol.
        #
        # @private
        # @param [RBS::Types::Function] func RBS function for rest keywords
        # @return [Docscribe::Types::RestKeywords, nil]
        def build_rest_keywords(func)
          rk = func.rest_keywords
          return nil unless rk

          value_type = format_type(rk.type)

          RestKeywords.new(
            name: rk.name&.to_s,
            type: "Hash<Symbol, #{value_type}>"
          )
        end

        # Format an RBS type object into the YARD-ish type syntax used by
        # generated comments.
        #
        # @private
        # @param [Docscribe::Types::RBS::TypeFormatter::rbs_type] type RBS type object to format
        # @return [String]
        def format_type(type)
          Docscribe::Types::RBS::TypeFormatter.to_yard(
            type,
            collapse_generics: @collapse_generics,
            collapse_object_generics: @collapse_object_generics
          )
        end

        # Normalize container names so lookups are consistent.
        #
        # @private
        # @param [String] name method name
        # @return [String]
        def normalize_container(name)
          name.to_s.delete_prefix('::').sub(/\[.*\]/, '').sub(/<.*>/, '')
        end

        # Print one debug warning per provider instance when debugging is enabled.
        #
        # @private
        # @param [String] msg warning message text
        # @return [void]
        def warn_once(msg)
          return unless ENV['DOCSCRIBE_RBS_DEBUG'] == '1'
          return if @warned

          @warned = true
          warn msg
        end
      end
    end
  end
end

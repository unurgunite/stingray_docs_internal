# frozen_string_literal: true

require_relative 'types'

module Docscribe
  module Types
    # YARD type parser
    module Yard
      class << self
        # @param [String?] string
        # @return [Docscribe::Types::Yard::node?]
        def parse(string)
          return nil if string.nil? || string.strip.empty?

          Parser.new(string).parse
        end
      end

      # Parses YARD type strings into an AST
      class Parser
        # @param [String] string
        # @return [void]
        def initialize(string)
          @s = string.strip
          @i = 0
        end

        # @return [Docscribe::Types::Yard::node]
        def parse
          skip_space
          node = parse_union
          skip_space
          node
        end

        private

        # @private
        # @return [Docscribe::Types::Yard::node]
        def parse_union
          types = [parse_intersection]
          skip_space
          while peek == ','
            @i += 1
            skip_space
            types << parse_intersection
            skip_space
          end
          types.size == 1 ? types.first : Union.new(types: types)
        end

        # @private
        # @return [Docscribe::Types::Yard::node]
        def parse_intersection
          types = [parse_optional]
          skip_space
          while peek == '&'
            @i += 1
            skip_space
            types << parse_optional
            skip_space
          end
          types.size == 1 ? types.first : Intersection.new(types: types)
        end

        # @private
        # @return [Docscribe::Types::Yard::node]
        def parse_optional
          type = parse_primary
          skip_space
          if peek == '?'
            @i += 1
            Optional.new(type: type)
          else
            type
          end
        end

        # @private
        # @return [Docscribe::Types::Yard::node]
        def parse_primary
          skip_space
          case peek
          when '(' then parse_tuple
          when '{' then parse_hash_map
          when '#' then parse_duck_type
          else
            parse_named_type
          end
        end

        # @private
        # @return [Docscribe::Types::Yard::Named, Docscribe::Types::Yard::Literal, Docscribe::Types::Yard::Generic, Docscribe::Types::Yard::HashMap]
        def parse_named_type
          name = scan_name
          return Literal.new(value: name) if literal?(name)

          skip_space
          if peek == '<'
            parse_generic(Named.new(name: name))
          elsif peek == '{'
            parse_named_hash_map
          else
            Named.new(name: name)
          end
        end

        # @private
        # @param [Docscribe::Types::Yard::Named] base
        # @return [Docscribe::Types::Yard::Generic]
        def parse_generic(base)
          @i += 1
          args = parse_generic_args
          @i += 1 if peek == '>'
          Generic.new(base: base.name, args: args)
        end

        # @private
        # @return [Docscribe::Types::Yard::node]
        def parse_generic_arg
          types = [parse_intersection]
          skip_space
          while peek == '|'
            @i += 1
            skip_space
            types << parse_intersection
            skip_space
          end
          types.size == 1 ? types.first : Union.new(types: types)
        end

        # @private
        # @return [Array<Docscribe::Types::Yard::node>]
        def parse_generic_args
          args = [] #: Array[untyped]
          skip_space
          while peek && peek != '>'
            args << parse_generic_arg
            skip_space
            next unless peek == ','

            @i += 1
            skip_space
          end
          args
        end

        # @private
        # @return [Docscribe::Types::Yard::Tuple]
        def parse_tuple
          @i += 1
          types = [] #: Array[untyped]
          while peek && peek != ')'
            types << parse_tuple_element
            @i += 1 and skip_space if peek == ','
          end
          @i += 1 if peek == ')'
          Tuple.new(types: types)
        end

        # @private
        # @return [Docscribe::Types::Yard::node]
        def parse_tuple_element
          type = parse_intersection
          skip_space
          if peek == '?'
            @i += 1
            Optional.new(type: type)
          else
            type
          end
        end

        # @private
        # @return [Docscribe::Types::Yard::HashMap]
        def parse_hash_map
          @i += 1
          key = parse_union
          @i += 2 if @s[@i, 2] == '=>'
          value = parse_union
          @i += 1 if peek == '}'
          HashMap.new(key_type: key, value_type: value)
        end

        # @private
        # @return [Docscribe::Types::Yard::HashMap]
        def parse_named_hash_map
          parse_hash_map
        end

        # @private
        # @return [Docscribe::Types::Yard::Duck]
        def parse_duck_type
          methods = [] #: Array[String]
          while peek == '#'
            @i += 1
            name = scan_name
            methods << name
            skip_space
          end
          Duck.new(method_names: methods)
        end

        # @private
        # @return [String]
        def scan_name
          start = @i
          loop do
            c = peek
            break unless c && name_char?(c)

            @i += 1
          end
          @s[start...@i]
        end

        # @private
        # @param [String] char
        # @return [Boolean]
        def name_char?(char)
          char.match?(/[a-zA-Z0-9_:]/)
        end

        # @private
        # @param [String] name
        # @return [Boolean]
        def literal?(name)
          %w[void nil self true false].include?(name)
        end

        # @private
        # @return [void]
        def skip_space
          @i += 1 while peek&.match?(/\s/)
        end

        # @private
        # @return [String?]
        def peek #: String?
          @s[@i]
        end
      end
    end
  end
end

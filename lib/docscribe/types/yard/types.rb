# frozen_string_literal: true

module Docscribe
  module Types
    module Yard
      # @!attribute [rw] name
      #   @return [String]
      #   @param [String] value
      #: Class[Docscribe::Types::Yard::Named]
      Named = Struct.new(:name, keyword_init: true)
      # @!attribute [rw] base
      #   @return [String]
      #   @param [String] value
      #
      # @!attribute [rw] args
      #   @return [Array<Docscribe::Types::Yard::node>]
      #   @param [Array<Docscribe::Types::Yard::node>] value
      #: Class[Docscribe::Types::Yard::Generic]
      Generic = Struct.new(:base, :args, keyword_init: true)
      # @!attribute [rw] types
      #   @return [Array<Docscribe::Types::Yard::node>]
      #   @param [Array<Docscribe::Types::Yard::node>] value
      #: Class[Docscribe::Types::Yard::Union]
      Union = Struct.new(:types, keyword_init: true)
      # @!attribute [rw] types
      #   @return [Array<Docscribe::Types::Yard::node>]
      #   @param [Array<Docscribe::Types::Yard::node>] value
      #: Class[Docscribe::Types::Yard::Intersection]
      Intersection = Struct.new(:types, keyword_init: true)
      # @!attribute [rw] type
      #   @return [Docscribe::Types::Yard::node]
      #   @param [Docscribe::Types::Yard::node] value
      #: Class[Docscribe::Types::Yard::Optional]
      Optional = Struct.new(:type, keyword_init: true)
      # @!attribute [rw] types
      #   @return [Array<Docscribe::Types::Yard::node>]
      #   @param [Array<Docscribe::Types::Yard::node>] value
      #: Class[Docscribe::Types::Yard::Tuple]
      Tuple = Struct.new(:types, keyword_init: true)
      # @!attribute [rw] key_type
      #   @return [Docscribe::Types::Yard::node]
      #   @param [Docscribe::Types::Yard::node] value
      #
      # @!attribute [rw] value_type
      #   @return [Docscribe::Types::Yard::node]
      #   @param [Docscribe::Types::Yard::node] value
      #: Class[Docscribe::Types::Yard::HashMap]
      HashMap = Struct.new(:key_type, :value_type, keyword_init: true)
      # @!attribute [rw] method_names
      #   @return [Array<String>]
      #   @param [Array<String>] value
      #: Class[Docscribe::Types::Yard::Duck]
      Duck = Struct.new(:method_names, keyword_init: true)
      # @!attribute [rw] value
      #   @return [String]
      #   @param [String] value
      #: Class[Docscribe::Types::Yard::Literal]
      Literal = Struct.new(:value, keyword_init: true)
    end
  end
end

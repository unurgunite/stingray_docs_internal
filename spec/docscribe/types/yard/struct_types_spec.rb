# frozen_string_literal: true

require 'docscribe/types/yard/parser'

RSpec.describe Docscribe::Types::Yard do
  describe 'Struct Class generics annotations' do
    context 'with Named struct' do
      let(:instance) { Docscribe::Types::Yard::Named.new(name: 'Foo') }

      it 'defines Named as Struct with keyword_init', :aggregate_failures do
        expect(Docscribe::Types::Yard::Named).to be_a(Class)
        expect(instance.name).to eq('Foo')
      end
    end

    context 'with Generic struct' do
      let(:generic) { Docscribe::Types::Yard::Generic.new(base: 'Array', args: []) }

      it 'defines Generic with base and args', :aggregate_failures do
        expect(generic.base).to eq('Array')
        expect(generic.args).to eq([])
      end
    end

    context 'with Union struct' do
      let(:union) { Docscribe::Types::Yard::Union.new(types: []) }

      it 'defines Union with types' do
        expect(union.types).to eq([])
      end
    end

    context 'with Intersection struct' do
      let(:intersection) { Docscribe::Types::Yard::Intersection.new(types: []) }

      it 'defines Intersection with types' do
        expect(intersection.types).to eq([])
      end
    end

    context 'with Optional struct' do
      let(:inner) { Docscribe::Types::Yard::Named.new(name: 'String') }
      let(:optional) { Docscribe::Types::Yard::Optional.new(type: inner) }

      it 'defines Optional with type' do
        expect(optional.type).to eq(inner)
      end
    end

    context 'with Tuple struct' do
      let(:tuple) { Docscribe::Types::Yard::Tuple.new(types: []) }

      it 'defines Tuple with types' do
        expect(tuple.types).to eq([])
      end
    end

    context 'with HashMap struct' do
      let(:key) { Docscribe::Types::Yard::Named.new(name: 'String') }
      let(:value) { Docscribe::Types::Yard::Named.new(name: 'Integer') }
      let(:hash_map) { Docscribe::Types::Yard::HashMap.new(key_type: key, value_type: value) }

      it 'defines HashMap with key and value', :aggregate_failures do
        expect(hash_map.key_type).to eq(key)
        expect(hash_map.value_type).to eq(value)
      end
    end

    context 'with Duck struct' do
      let(:duck) { Docscribe::Types::Yard::Duck.new(method_names: %w[foo bar]) }

      it 'defines Duck with method_names' do
        expect(duck.method_names).to eq(%w[foo bar])
      end
    end

    context 'with Literal struct' do
      let(:literal) { Docscribe::Types::Yard::Literal.new(value: 'void') }

      it 'defines Literal with value' do
        expect(literal.value).to eq('void')
      end
    end
  end
end

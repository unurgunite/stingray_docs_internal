# frozen_string_literal: true

require 'docscribe/types/yard/parser'
require 'docscribe/types/yard/formatter'

RSpec.describe Docscribe::Types::Yard do
  describe '.parse' do
    it 'returns nil for nil' do
      expect(parse(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(parse('')).to be_nil
    end

    it 'returns nil for whitespace' do
      expect(parse('   ')).to be_nil
    end

    context 'when parsing simple named type' do
      let(:node) { parse('String') }

      it 'parses a simple named type', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Named)
        expect(node.name).to eq('String')
      end
    end

    context 'when parsing namespaced type' do
      let(:node) { parse('Foo::Bar') }

      it 'parses namespaced type', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Named)
        expect(node.name).to eq('Foo::Bar')
      end
    end

    context 'when parsing Boolean' do
      let(:node) { parse('Boolean') }

      it 'parses Boolean as named' do
        expect(node).to be_a(Docscribe::Types::Yard::Named)
      end
    end

    context 'when parsing void' do
      let(:node) { parse('void') }

      it 'parses void as literal', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Literal)
        expect(node.value).to eq('void')
      end
    end

    context 'when parsing nil literal' do
      let(:node) { parse('nil') }

      it 'parses nil as literal', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Literal)
        expect(node.value).to eq('nil')
      end
    end

    context 'when parsing self' do
      let(:node) { parse('self') }

      it 'parses self as literal', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Literal)
        expect(node.value).to eq('self')
      end
    end

    context 'when parsing generic Array<String>' do
      let(:node) { parse('Array<String>') }

      it 'parses generic Array<String>', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Generic).and have_attributes(base: 'Array')
        expect(node.args.first).to be_a(Docscribe::Types::Yard::Named).and have_attributes(name: 'String')
      end
    end

    context 'when parsing generic with multiple args' do
      let(:node) { parse('Hash<Symbol, Object>') }

      it 'parses generic with multiple args' do
        expect(node.args.map(&:name)).to eq(%w[Symbol Object])
      end
    end

    context 'when parsing generic arg with union' do
      let(:node) { parse('Hash<String | Integer, Object>') }

      it 'parses generic arg with union' do
        expect(node.args[0].types.map(&:name)).to eq(%w[String Integer])
      end
    end

    context 'when parsing generic with nested generics' do
      let(:node) { parse('Array<Array<String>>') }

      it 'parses generic with nested generics', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Generic).and have_attributes(base: 'Array')
        expect(node.args.first.args.first.name).to eq('String')
      end
    end

    context 'when parsing hash map syntax' do
      let(:node) { parse('Hash{String => Integer}') }

      it 'parses hash map syntax', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::HashMap)
        expect([node.key_type.name, node.value_type.name]).to eq(%w[String Integer])
      end
    end

    context 'when parsing bare hash map' do
      let(:node) { parse('{String => Integer}') }

      it 'parses bare hash map', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::HashMap)
        expect([node.key_type.name, node.value_type.name]).to eq(%w[String Integer])
      end
    end

    context 'when parsing union with comma' do
      let(:node) { parse('String, Integer') }

      it 'parses union with comma', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Union)
        expect(node.types.size).to eq(2)
      end
    end

    context 'when parsing union with three types' do
      let(:node) { parse('String, Integer, nil') }

      it 'parses union with three types', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Union)
        expect(node.types.size).to eq(3)
      end
    end

    context 'when parsing optional' do
      let(:node) { parse('String?') }

      it 'parses optional', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Optional)
        expect(node.type).to be_a(Docscribe::Types::Yard::Named).and have_attributes(name: 'String')
      end
    end

    context 'when parsing tuple' do
      let(:node) { parse('(String, Integer)') }

      it 'parses tuple', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Tuple)
        expect(node.types).to match([have_attributes(name: 'String'), have_attributes(name: 'Integer')])
      end
    end

    context 'when parsing intersection' do
      let(:node) { parse('String & Integer') }

      it 'parses intersection', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Intersection)
        expect(node.types.size).to eq(2)
      end
    end

    context 'when parsing duck type' do
      let(:node) { parse('#foo') }

      it 'parses duck type', :aggregate_failures do
        expect(node).to be_a(Docscribe::Types::Yard::Duck)
        expect(node.method_names).to eq(%w[foo])
      end
    end
  end

  describe 'Formatter.to_rbs' do
    it 'converts String' do
      expect(to_rbs(parse('String'))).to eq('String')
    end

    it 'converts Integer' do
      expect(to_rbs(parse('Integer'))).to eq('Integer')
    end

    it 'converts Boolean to bool' do
      expect(to_rbs(parse('Boolean'))).to eq('bool')
    end

    it 'converts Object to untyped' do
      expect(to_rbs(parse('Object'))).to eq('untyped')
    end

    it 'converts void' do
      expect(to_rbs(parse('void'))).to eq('void')
    end

    it 'converts nil' do
      expect(to_rbs(parse('nil'))).to eq('nil')
    end

    it 'converts self' do
      expect(to_rbs(parse('self'))).to eq('self')
    end

    it 'converts Array<String>' do
      expect(to_rbs(parse('Array<String>'))).to eq('Array[String]')
    end

    it 'converts Hash{String => Integer}' do
      expect(to_rbs(parse('Hash{String => Integer}'))).to eq('Hash[String, Integer]')
    end

    it 'converts Hash{Symbol => Object}' do
      expect(to_rbs(parse('Hash{Symbol => Object}'))).to eq('Hash[Symbol, untyped]')
    end

    it 'converts union' do
      expect(to_rbs(parse('String, Integer'))).to eq('String | Integer')
    end

    it 'converts optional' do
      expect(to_rbs(parse('String?'))).to eq('String?')
    end

    it 'converts tuple' do
      expect(to_rbs(parse('(String, Integer)'))).to eq('[String, Integer]')
    end

    it 'converts intersection' do
      expect(to_rbs(parse('String & Integer'))).to eq('String & Integer')
    end

    it 'converts Hash<Symbol, Object>' do
      expect(to_rbs(parse('Hash<Symbol, Object>'))).to eq('Hash[Symbol, untyped]')
    end

    it 'converts nested generic with hash map' do
      expect(to_rbs(parse('Array<Hash{String => Integer}>'))).to eq('Array[Hash[String, Integer]]')
    end

    it 'converts nil to untyped' do
      expect(to_rbs(nil)).to eq('untyped')
    end
  end
end

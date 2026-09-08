# frozen_string_literal: true

# rubocop:disable RSpec/NestedGroups

require 'docscribe/types/yard/parser'
require 'docscribe/types/yard/formatter'

RSpec.describe Docscribe::Types::Yard::Formatter do
  describe '.to_rbs' do
    subject(:rbs) { described_class.to_rbs(node) }

    context 'when node is nil' do
      let(:node) { nil }

      it { is_expected.to eq('untyped') }
    end

    context 'when node is Named String' do
      let(:node) { Docscribe::Types::Yard.parse('String') }

      it { is_expected.to eq('String') }
    end

    context 'when node is Named Boolean' do
      let(:node) { Docscribe::Types::Yard.parse('Boolean') }

      it { is_expected.to eq('bool') }
    end

    context 'when node is Named Object' do
      let(:node) { Docscribe::Types::Yard.parse('Object') }

      it { is_expected.to eq('untyped') }
    end

    context 'when node is Named with namespace' do
      let(:node) { Docscribe::Types::Yard.parse('Foo::Bar') }

      it { is_expected.to eq('Foo::Bar') }
    end

    context 'when node is Literal void' do
      let(:node) { Docscribe::Types::Yard.parse('void') }

      it { is_expected.to eq('void') }
    end

    context 'when node is Literal nil' do
      let(:node) { Docscribe::Types::Yard.parse('nil') }

      it { is_expected.to eq('nil') }
    end

    context 'when node is Literal self' do
      let(:node) { Docscribe::Types::Yard.parse('self') }

      it { is_expected.to eq('self') }
    end

    context 'when node is Literal true' do
      let(:node) { Docscribe::Types::Yard.parse('true') }

      it { is_expected.to eq('bool') }
    end

    context 'when node is Literal false' do
      let(:node) { Docscribe::Types::Yard.parse('false') }

      it { is_expected.to eq('bool') }
    end

    context 'when node is Literal unknown (else branch)' do
      let(:node) { Docscribe::Types::Yard::Literal.new(value: 'unknown') }

      it { is_expected.to eq('untyped') }
    end

    context 'when node is Generic Array<String>' do
      let(:node) { Docscribe::Types::Yard.parse('Array<String>') }

      it { is_expected.to eq('Array[String]') }
    end

    context 'when node is Generic Hash with two args' do
      let(:node) { Docscribe::Types::Yard.parse('Hash<Symbol, Integer>') }

      it { is_expected.to eq('Hash[Symbol, Integer]') }
    end

    context 'when node is Generic nested Array<Array<String>>' do
      let(:node) { Docscribe::Types::Yard.parse('Array<Array<String>>') }

      it { is_expected.to eq('Array[Array[String]]') }
    end

    context 'when node is Union String, Integer' do
      let(:node) { Docscribe::Types::Yard.parse('String, Integer') }

      it { is_expected.to eq('String | Integer') }
    end

    context 'when node is Union with three types' do
      let(:node) { Docscribe::Types::Yard.parse('String, Integer, nil') }

      it { is_expected.to eq('String | Integer | nil') }
    end

    context 'when node is Intersection String & Integer' do
      let(:node) { Docscribe::Types::Yard.parse('String & Integer') }

      it { is_expected.to eq('String & Integer') }
    end

    context 'when node is Optional String?' do
      let(:node) { Docscribe::Types::Yard.parse('String?') }

      it { is_expected.to eq('String?') }
    end

    context 'when node is Tuple (String, Integer)' do
      let(:node) { Docscribe::Types::Yard.parse('(String, Integer)') }

      it { is_expected.to eq('[String, Integer]') }
    end

    context 'when node is HashMap {String => Integer}' do
      let(:node) { Docscribe::Types::Yard.parse('{String => Integer}') }

      it { is_expected.to eq('Hash[String, Integer]') }
    end

    context 'when node is HashMap Hash{Symbol => String}' do
      let(:node) { Docscribe::Types::Yard.parse('Hash{Symbol => String}') }

      it { is_expected.to eq('Hash[Symbol, String]') }
    end

    context 'when node is Duck type (unhandled)' do
      let(:node) { Docscribe::Types::Yard.parse('#foo') }

      it { is_expected.to eq('untyped') }
    end
  end

  describe 'private dispatch' do
    describe '.rbs_for_node' do
      subject(:dispatched) { described_class.send(:rbs_for_node, node) }

      context 'when node is Named' do
        let(:node) { Docscribe::Types::Yard.parse('String') }

        it { is_expected.to eq('String') }
      end

      context 'when node is Union' do
        let(:node) { Docscribe::Types::Yard.parse('String, Integer') }

        it { is_expected.to eq('String | Integer') }
      end

      context 'when node is Generic' do
        let(:node) { Docscribe::Types::Yard.parse('Array<String>') }

        it { is_expected.to eq('Array[String]') }
      end

      context 'when node is Duck (no handler)' do
        let(:node) { Docscribe::Types::Yard.parse('#foo') }

        it { is_expected.to be_nil }
      end
    end

    describe '.simple_type' do
      subject(:simple) { described_class.send(:simple_type, node) }

      context 'when Named' do
        let(:node) { Docscribe::Types::Yard.parse('String') }

        it { is_expected.to eq('String') }
      end

      context 'when Literal' do
        let(:node) { Docscribe::Types::Yard.parse('nil') }

        it { is_expected.to eq('nil') }
      end

      context 'when Union (not simple)' do
        let(:node) { Docscribe::Types::Yard.parse('String, Integer') }

        it { is_expected.to be_nil }
      end

      context 'when Generic (not simple)' do
        let(:node) { Docscribe::Types::Yard.parse('Array<String>') }

        it { is_expected.to be_nil }
      end
    end

    describe '.composite_type' do
      subject(:composite) { described_class.send(:composite_type, node) }

      context 'when Union' do
        let(:node) { Docscribe::Types::Yard.parse('String, Integer') }

        it { is_expected.to eq('String | Integer') }
      end

      context 'when Intersection' do
        let(:node) { Docscribe::Types::Yard.parse('String & Integer') }

        it { is_expected.to eq('String & Integer') }
      end

      context 'when Optional' do
        let(:node) { Docscribe::Types::Yard.parse('String?') }

        it { is_expected.to eq('String?') }
      end

      context 'when Named (not composite)' do
        let(:node) { Docscribe::Types::Yard.parse('String') }

        it { is_expected.to be_nil }
      end

      context 'when Generic (not composite)' do
        let(:node) { Docscribe::Types::Yard.parse('Array<String>') }

        it { is_expected.to be_nil }
      end
    end

    describe '.collection_type' do
      subject(:collection) { described_class.send(:collection_type, node) }

      context 'when Generic' do
        let(:node) { Docscribe::Types::Yard.parse('Array<String>') }

        it { is_expected.to eq('Array[String]') }
      end

      context 'when Tuple' do
        let(:node) { Docscribe::Types::Yard.parse('(String, Integer)') }

        it { is_expected.to eq('[String, Integer]') }
      end

      context 'when HashMap' do
        let(:node) { Docscribe::Types::Yard.parse('{String => Integer}') }

        it { is_expected.to eq('Hash[String, Integer]') }
      end

      context 'when Named (not collection)' do
        let(:node) { Docscribe::Types::Yard.parse('String') }

        it { is_expected.to be_nil }
      end

      context 'when Union (not collection)' do
        let(:node) { Docscribe::Types::Yard.parse('String, Integer') }

        it { is_expected.to be_nil }
      end
    end
  end
end
# rubocop:enable RSpec/NestedGroups

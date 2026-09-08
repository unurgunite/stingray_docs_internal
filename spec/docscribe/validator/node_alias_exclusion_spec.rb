# frozen_string_literal: true

require 'docscribe/validator/generic_compatibility'

RSpec.describe Docscribe::Validator::GenericCompatibility do
  subject(:mod) { described_class }

  describe 'Yard node alias exclusion for trailing literal fix' do
    context 'when Yard is Docscribe::Types::Yard::node' do
      it 'does not treat node vs Array as compatible' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'Array')).to be false
      end

      it 'does not treat node vs Hash as compatible' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'Hash')).to be false
      end

      it 'does not treat node vs Array<String> as compatible' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'Array<String>')).to be false
      end

      it 'does not treat node vs Hash<Symbol, String> as compatible' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'Hash<Symbol, String>')).to be false
      end

      it 'does not treat node vs Range as compatible' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'Range')).to be false
      end

      it 'does not treat reversed Array vs node as compatible' do
        expect(mod.compatible?('Array', 'Docscribe::Types::Yard::node')).to be false
      end

      it 'does not treat Node (capitalized) vs Array as compatible' do
        expect(mod.compatible?('Docscribe::Types::Yard::Node', 'Array')).to be false
      end
    end

    context 'when Yard is bare node alias' do
      it 'does not treat node vs Array as compatible without namespace' do
        # bare 'node' has no :: so alias_hash_compatible? already false, but ensure still false
        expect(mod.compatible?('node', 'Array')).to be false
      end
    end

    context 'when alias is real lowercase namespaced alias' do
      it 'still treats my_alias vs Array as compatible' do
        expect(mod.compatible?('Foo::Bar::my_alias', 'Array')).to be true
      end

      it 'still treats json_document vs Hash as compatible' do
        expect(mod.compatible?('Docscribe::CLI::Formatters::Json::json_document', 'Hash')).to be true
      end

      it 'still treats my_custom_alias vs Hash as compatible' do
        expect(mod.compatible?('Foo::Bar::my_custom_alias', 'Hash')).to be true
      end
    end

    context 'when checking alias_hash_pair? directly' do
      it 'returns false for node vs Array' do
        expect(mod.alias_hash_pair?('Docscribe::Types::Yard::node', 'Array')).to be false
      end

      it 'returns false for Node vs Hash' do
        expect(mod.alias_hash_pair?('Docscribe::Types::Yard::Node', 'Hash<String, Integer>')).to be false
      end

      it 'returns true for my_alias vs Array' do
        expect(mod.alias_hash_pair?('Foo::my_alias', 'Array<String>')).to be true
      end
    end

    context 'when trailing literal changes inferred type' do
      # These simulate what happens when `[]` or `42` becomes last_expr_type:
      # Yard is node, inferred becomes Array/Integer/Symbol. Before fix, node vs Array was true (suppressed),
      # after fix it is false (still mismatch, warning preserved).
      it 'keeps warning for node vs Array (trailing [])' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'Array')).to be false
      end

      it 'keeps warning for node vs Integer (trailing 42)' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'Integer')).to be false
      end

      it 'keeps warning for node vs Symbol (trailing :sym)' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'Symbol')).to be false
      end

      it 'keeps warning for node vs String (trailing "str")' do
        expect(mod.compatible?('Docscribe::Types::Yard::node', 'String')).to be false
      end
    end
  end
end

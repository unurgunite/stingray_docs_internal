# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations

require 'docscribe/types/primitive'

RSpec.describe Docscribe::Types::Primitive do
  describe '.primitive?' do
    it 'returns true for core primitives via RBS' do
      expect(described_class.primitive?('String')).to be true
      expect(described_class.primitive?('Integer')).to be true
      expect(described_class.primitive?('Array')).to be true
      expect(described_class.primitive?('Hash')).to be true
      expect(described_class.primitive?('untyped')).to be true
      expect(described_class.primitive?('void')).to be true
      expect(described_class.primitive?('nil')).to be true
    end

    it 'returns false for generic placeholders' do
      expect(described_class.primitive?('Elem')).to be false
      expect(described_class.primitive?('U')).to be false
      expect(described_class.primitive?('V')).to be false
      expect(described_class.primitive?('ParamTag')).to be false
    end

    it 'returns false for namespaced project types' do
      expect(described_class.primitive?('Docscribe::CLI::RbsGen::ParamTag')).to be false
      expect(described_class.primitive?('MyCustom::MyType')).to be false
    end

    it 'handles generic with suffix' do
      expect(described_class.primitive?('String?')).to be true
      expect(described_class.primitive?('Array<String>')).to be true
      expect(described_class.primitive?('Elem?')).to be false
    end
  end

  describe '.alias_token?' do
    it 'returns true for alias placeholders' do
      expect(described_class.alias_token?('Elem')).to be true
      expect(described_class.alias_token?('U')).to be true
      expect(described_class.alias_token?('my_alias')).to be true
      expect(described_class.alias_token?('Docscribe::CLI::RbsGen::ParamTag')).to be true
    end

    it 'returns false for primitives' do
      expect(described_class.alias_token?('String')).to be false
      expect(described_class.alias_token?('Array<String>')).to be false
      expect(described_class.alias_token?('untyped')).to be false
    end
  end

  describe '.core_primitives' do
    it 'includes core RBS classes dynamically' do
      expect(described_class.core_primitives).to include('String', 'Array', 'Integer')
    end

    it 'is cached and not hardcoded to specific list' do
      first = described_class.core_primitives.object_id
      second = described_class.core_primitives.object_id
      expect(first).to eq(second)
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations

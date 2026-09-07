# frozen_string_literal: true

require 'docscribe/validator/generic_compatibility'

RSpec.describe Docscribe::Validator::GenericCompatibility do
  subject(:mod) { described_class }

  describe 'bare alias and union handling (dynamic, no hardcode)' do
    it 'treats Array<String> vs Array<DEFAULT_ERROR> as compatible via inner alias' do
      expect(mod.compatible?('Array<String>', 'Array<DEFAULT_ERROR>')).to be true
    end

    it 'treats Array<String> vs Array, Array<DEFAULT_ERROR>, Array as compatible via union parts' do
      expect(mod.compatible?('Array<String>', 'Array, Array<DEFAULT_ERROR>, Array')).to be true
    end

    it 'treats Array<String> vs V as compatible via bare single capital' do
      expect(mod.compatible?('Array<String>', 'V')).to be true
    end

    it 'treats V vs Array<String> as compatible via bare alias' do
      expect(mod.compatible?('V', 'Array<String>')).to be true
    end

    it 'does not treat Array<String> vs Array<Object> as compatible' do
      expect(mod.compatible?('Array<String>', 'Array<Object>')).to be false
    end

    it 'treats DEFAULT_ERROR as alias token' do
      expect(Docscribe::Types::Primitive.alias_token?('DEFAULT_ERROR')).to be true
    end

    it 'treats Array<Elem> vs Array<String> as compatible' do
      expect(mod.compatible?('Array<Elem>', 'Array<String>')).to be true
    end

    it 'handles union_parts_compatible? directly for single vs union' do
      expect(mod.send(:union_parts_compatible?, 'Array<String>', 'Array, Array<DEFAULT_ERROR>, Array', 'Object', nil)).to be true
    end

    it 'returns false for non-union single vs single via union_parts_compatible?' do
      expect(mod.send(:union_parts_compatible?, 'String', 'Integer', 'Object', nil)).to be false
    end
  end

  describe 'helper coverage for optional and split' do
    it 'canonicalizes String? and String, nil to same sorted parts' do
      expect(mod.send(:optional_canonical_parts, 'String?')).to eq(%w[String nil])
      expect(mod.send(:optional_canonical_parts, 'String, nil')).to eq(%w[String nil])
    end

    it 'handles pipe syntax and blank via empty_str? and normalized_union_str' do
      expect(mod.send(:optional_canonical_parts, 'String | nil')).to eq(%w[String nil])
      expect(mod.send(:optional_canonical_parts, '   ')).to eq([])
    end

    it 'splits nested generics via handle_split_char depth tracking' do
      parts = mod.send(:split_top_level_commas_local, 'Hash<String, Array<Integer>>, String')
      expect(parts.map(&:strip)).to eq(['Hash<String, Array<Integer>>', 'String'])
    end

    it 'covers void helpers with initialize/setup' do
      expect(mod.send(:void_compatible?, 'void', 'Hash', method_name: :initialize)).to be true
      expect(mod.send(:void_compatible?, 'void', 'Hash', method_name: :setup)).to be true
    end

    it 'covers primitive normalized_base stripping ? and generics' do
      expect(Docscribe::Types::Primitive.send(:normalized_base, 'String?')).to eq('String')
      expect(Docscribe::Types::Primitive.send(:normalized_base, 'Array<String>')).to eq('Array')
    end
  end
end

# frozen_string_literal: true

require 'docscribe/types/yard/validator'

RSpec.describe Docscribe::Types::Yard::Validator do
  describe '.valid?' do
    it 'returns false for nil' do
      expect(nil).to be_invalid_yard_type
    end

    it 'returns false for empty string' do
      expect('').to be_invalid_yard_type
    end

    it 'returns false for whitespace' do
      expect('   ').to be_invalid_yard_type
    end

    it 'returns true for simple types' do
      aggregate_failures do
        expect('String').to be_valid_yard_type
        expect('Integer').to be_valid_yard_type
        expect('Symbol').to be_valid_yard_type
      end
    end

    it 'returns false for leftover content like Sym bol' do
      expect('Sym bol').to be_invalid_yard_type
    end

    it 'returns true for union with comma' do
      expect('String, Integer').to be_valid_yard_type
    end

    it 'returns false for double comma' do
      expect('String,, Integer').to be_invalid_yard_type
    end

    it 'returns false for unbalanced brackets' do
      aggregate_failures do
        expect('Array<String').to be_invalid_yard_type
        expect('Array<String>>').to be_invalid_yard_type
      end
    end

    it 'returns true for generic' do
      aggregate_failures do
        expect('Array<String>').to be_valid_yard_type
        expect('Hash<Symbol, Integer>').to be_valid_yard_type
      end
    end

    it 'returns true for optional' do
      expect('String?').to be_valid_yard_type
    end

    it 'returns true for namespaced type' do
      expect('Foo::Bar').to be_valid_yard_type
    end
  end

  describe '.syntax_valid?' do
    it 'delegates to valid? with balanced check', :aggregate_failures do
      expect('String').to be_valid_yard_syntax
      expect('Sym bol').not_to be_valid_yard_syntax
      expect('Array<String>').to be_valid_yard_syntax
      expect('Array<String').not_to be_valid_yard_syntax
    end
  end

  describe '.balanced_brackets?' do
    it 'checks angle brackets' do
      aggregate_failures do
        expect(balanced_yard_brackets?('Array<String>')).to be true
        expect(balanced_yard_brackets?('Array<String')).to be false
      end
    end

    it 'checks bracket' do
      aggregate_failures do
        expect(balanced_yard_brackets?('a[b]')).to be true
        expect(balanced_yard_brackets?('a[b')).to be false
      end
    end
  end

  describe '.fully_consumed?' do
    it 'returns false for Sym bol' do
      expect(fully_consumed_yard_type?('Sym bol')).to be false
    end

    it 'returns true for valid' do
      expect(fully_consumed_yard_type?('Symbol')).to be true
    end
  end
end

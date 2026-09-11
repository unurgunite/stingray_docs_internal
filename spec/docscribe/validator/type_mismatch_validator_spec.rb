# frozen_string_literal: true

require 'docscribe/validator/type_mismatch_validator'

RSpec.describe Docscribe::Validator::TypeMismatchValidator do
  subject(:validator) { described_class.new(fallback_type: 'Object') }

  describe '#mismatched_return?' do
    context 'when yard and expected match' do
      it 'returns false' do
        expect(validator.mismatched_return?('String', 'String')).to be false
      end
    end

    context 'when yard and expected differ' do
      it 'returns true' do
        expect(validator.mismatched_return?('Integer', 'String')).to be true
      end
    end

    context 'when expected is fallback' do
      it 'returns false' do
        expect(validator.mismatched_return?('Integer', 'Object')).to be false
      end
    end

    context 'when yard is nil' do
      it 'returns false' do
        expect(validator.mismatched_return?(nil, 'String')).to be false
      end
    end

    it 'handles whitespace normalization' do
      expect(validator.mismatched_return?(' String ', 'String')).to be false
    end

    describe 'generic Hash compatibility' do
      it 'returns false when yard is generic Hash and expected is detailed Hash<Symbol, String>' do
        expect(validator.mismatched_return?('Hash', 'Hash<Symbol, String>')).to be false
      end

      it 'returns false when yard is detailed Hash<Symbol, String> and expected is generic Hash' do
        expect(validator.mismatched_return?('Hash<Symbol, String>', 'Hash')).to be false
      end

      it 'returns false for complex Hash vs generic Hash' do
        expect(validator.mismatched_return?('Hash<Symbol, Docscribe::Config, String, Parser::Source::Buffer>', 'Hash')).to be false
      end

      it 'returns true when both detailed Hash types differ' do
        expect(validator.mismatched_return?('Hash<Symbol, String>', 'Hash<Symbol, Integer>')).to be true
      end

      it 'normalizes RBS [] and untyped to YARD <> and Object for comparison', :aggregate_failures do
        expect(validator.mismatched_return?('Hash[Symbol, untyped]', 'Hash<Symbol, Object>')).to be false
        expect(validator.mismatched_return?('Hash<Symbol, Object>', 'Hash[Symbol, untyped]')).to be false
        expect(validator.mismatched_return?('Array[Integer]', 'Array<Integer>')).to be false
      end
    end
  end

  describe '#invalid_syntax?' do
    let(:invalid_type) { 'Sym bol' }

    it 'returns true for invalid type' do
      expect(validator.invalid_syntax?(invalid_type)).to be true
    end

    it 'returns false for valid type' do
      expect(validator.invalid_syntax?('String')).to be false
    end

    it 'returns false for nil' do
      expect(validator.invalid_syntax?(nil)).to be false
    end
  end

  describe '#check_return' do
    let(:invalid_yard) { 'Sym bol' }

    it 'returns invalid_syntax result for invalid yard', :aggregate_failures do
      validation_result = validator.check_return(invalid_yard, 'Symbol')
      expect(validation_result).not_to be_nil
      expect(validation_result.type).to eq(:invalid_syntax)
    end

    it 'returns type_mismatch when Integer vs String', :aggregate_failures do
      validation_result = validator.check_return('Integer', 'String')
      expect(validation_result.type).to eq(:type_mismatch_return)
      expect(validation_result.message).to include('Integer').and include('String')
    end

    it 'returns nil when matching' do
      expect(validator.check_return('String', 'String')).to be_nil
    end

    it 'returns nil when expected is fallback' do
      expect(validator.check_return('Integer', 'Object')).to be_nil
    end
  end

  describe '#check_param' do
    let(:invalid_yard) { 'Sym bol' }

    it 'returns invalid_syntax for invalid yard' do
      validation_result = validator.check_param('x', invalid_yard, 'String')
      expect(validation_result.type).to eq(:invalid_syntax)
    end

    it 'returns mismatch for String vs Integer', :aggregate_failures do
      validation_result = validator.check_param('x', 'String', 'Integer')
      expect(validation_result.type).to eq(:type_mismatch_param)
      expect(validation_result.message).to include('x')
    end

    it 'returns nil when matching' do
      expect(validator.check_param('x', 'String', 'String')).to be_nil
    end
  end

  describe 'source field' do
    let(:invalid_yard) { 'Sym bol' }

    it 'sets source syntax for invalid' do
      validation_result = validator.check_return(invalid_yard, 'Symbol')
      expect(validation_result.source).to eq('syntax')
    end

    it 'sets source infer for mismatch' do
      validation_result = validator.check_return('Integer', 'String')
      expect(validation_result.source).to eq('infer')
    end

    it 'sets source rbs when RBS type differs' do
      validation_result = validator.check_return('String', 'Integer')
      expect(validation_result.source).to eq('infer')
    end
  end
end

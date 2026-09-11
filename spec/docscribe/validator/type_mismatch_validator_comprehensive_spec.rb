# frozen_string_literal: true

require 'docscribe/validator/type_mismatch_validator'

RSpec.describe Docscribe::Validator::TypeMismatchValidator do
  subject(:validator) { described_class.new(fallback_type: 'Object') }

  describe 'Hash generic handling' do
    it 'treats generic Hash as compatible with Hash<Symbol, String>', :aggregate_failures do
      expect(validator.mismatched_return?('Hash', 'Hash<Symbol, String>')).to be false
      expect(validator.mismatched_return?('Hash<Symbol, String>', 'Hash')).to be false
    end

    it 'treats generic Hash as compatible with RBS Hash[Symbol, String]', :aggregate_failures do
      expect(validator.mismatched_return?('Hash', 'Hash[Symbol, String]')).to be false
      expect(validator.mismatched_return?('Hash[Symbol, String]', 'Hash')).to be false
      expect(validator.mismatched_return?('Hash[Symbol, untyped]', 'Hash<Symbol, Object>')).to be false
    end

    it 'detects mismatch when both detailed Hash differ', :aggregate_failures do
      expect(validator.mismatched_return?('Hash<Symbol, String>', 'Hash<Symbol, Integer>')).to be true
      expect(validator.mismatched_return?('Hash[Symbol, String]', 'Hash[Symbol, Integer]')).to be true
    end

    it 'handles complex Hash with many generics vs generic', :aggregate_failures do
      expect(validator.mismatched_return?('Hash<Symbol, Docscribe::Config, String, Parser::Source::Buffer>', 'Hash')).to be false
      expect(validator.mismatched_return?('Hash', 'Hash<Symbol, Docscribe::Config, String, Parser::Source::Buffer>')).to be false
    end

    it 'treats opts alias as compatible with Hash', :aggregate_failures do
      expect(validator.mismatched_return?('Docscribe::CLI::Formatters::opts', 'Hash')).to be false
      expect(validator.mismatched_return?('Hash', 'Docscribe::CLI::Formatters::opts')).to be false
      expect(validator.mismatched_return?('My::opts', 'Hash')).to be false
      expect(validator.mismatched_return?('Docscribe::CLI::Formatters::opts', 'Hash<Symbol, String>')).to be false
      expect(validator.mismatched_return?('Hash<Symbol, String>', 'Docscribe::CLI::Formatters::opts')).to be false
    end

    it 'treats parseInfo/setup aliases as Hash compatible', :aggregate_failures do
      expect(validator.mismatched_return?('Docscribe::InlineRewriter::DocBuilder::parseInfo', 'Hash')).to be false
      expect(validator.mismatched_return?('Hash', 'Docscribe::InlineRewriter::DocBuilder::parseInfo')).to be false
      expect(validator.mismatched_return?('Docscribe::InlineRewriter::DocBuilder::setup', 'Hash')).to be false
      expect(validator.mismatched_return?('Hash', 'Docscribe::InlineRewriter::DocBuilder::setup')).to be false
    end
  end

  describe 'Boolean tuple handling' do
    it 'treats tuple (String, Integer) as compatible with Array', :aggregate_failures do
      expect(validator.mismatched_return?('(String, Integer)', 'Array')).to be false
      expect(validator.mismatched_return?('Array', '(String, Integer)')).to be false
      expect(validator.mismatched_return?('(String, Symbol)', 'Array<String>')).to be true
    end

    it 'detects true mismatch for tuple vs non-Array', :aggregate_failures do
      expect(validator.mismatched_return?('(String, Integer)', 'Hash')).to be true
      expect(validator.mismatched_return?('(String, Integer)', 'String')).to be true
    end

    it 'handles whitespace-normalized tuple', :aggregate_failures do
      expect(validator.mismatched_return?('(String, Integer)', 'Array')).to be false
      expect(validator.mismatched_return?(' (String,  Integer) ', 'Array')).to be false
    end
  end

  describe '**kwargs Hash[Symbol, untyped] handling' do
    it 'normalizes RBS Hash[Symbol, untyped] to Hash<Symbol, Object> for comparison', :aggregate_failures do
      expect(validator.mismatched_return?('Hash[Symbol, untyped]', 'Hash<Symbol, Object>')).to be false
      expect(validator.mismatched_return?('Hash<Symbol, Object>', 'Hash[Symbol, untyped]')).to be false
      expect(validator.mismatched_return?('Array[Integer]', 'Array<Integer>')).to be false
      expect(validator.mismatched_return?('Array[Integer]', 'Array<String>')).to be true
    end

    it 'treats Hash[Symbol, untyped] as generic Hash compatible', :aggregate_failures do
      expect(validator.mismatched_return?('Hash[Symbol, untyped]', 'Hash')).to be false
      expect(validator.mismatched_return?('Hash', 'Hash[Symbol, untyped]')).to be false
    end

    context 'when types are compatible' do
      it 'returns nil for generic kwargs', :aggregate_failures do
        expect(validator.check_param('kwargs', 'Hash', 'Hash')).to be_nil
        expect(validator.check_param('kwargs', 'Hash', 'Hash[Symbol, untyped]')).to be_nil
      end
    end

    context 'when detailed Hash mismatch' do
      subject(:validation_result) { validator.check_param('kwargs', 'Hash<Symbol, String>', 'Hash<Symbol, Integer>') }

      it 'returns param mismatch', :aggregate_failures do
        expect(validation_result).not_to be_nil
        expect(validation_result.type).to eq(:type_mismatch_param)
      end
    end
  end

  describe 'FALLBACK_TYPE alias' do
    it 'normalizes FALLBACK_TYPE to Object', :aggregate_failures do
      expect(validator.mismatched_return?('FALLBACK_TYPE', 'Object')).to be false
      expect(validator.mismatched_return?('Object', 'FALLBACK_TYPE')).to be false
      expect(validator.mismatched_return?('Hash<FALLBACK_TYPE>', 'Hash<Object>')).to be false
    end

    it 'normalizes untyped to Object', :aggregate_failures do
      expect(validator.mismatched_return?('untyped', 'Object')).to be false
      expect(validator.mismatched_return?('Object', 'untyped')).to be false
    end

    context 'when expected is FALLBACK_TYPE alias' do
      let(:fallback_validator) { described_class.new(fallback_type: 'Object') }

      it 'silences when expected is FALLBACK_TYPE alias', :aggregate_failures do
        expect(fallback_validator.mismatched_return?('String', 'FALLBACK_TYPE')).to be false
        expect(fallback_validator.mismatched_return?('Integer', 'FALLBACK_TYPE')).to be false
        expect(fallback_validator.mismatched_return?('String', 'untyped')).to be false
      end
    end

    it 'handles whitespace and ? suffix with fallback', :aggregate_failures do
      expect(validator.mismatched_return?('String', 'Object?')).to be false
      expect(validator.send(:fallback_union?, 'Object?')).to be true
      expect(validator.send(:fallback_union?, 'Object, Object?')).to be true
    end

    describe '#fallback_union? detects unions of only fallback' do
      it 'returns true for Object' do
        expect(validator.send(:fallback_union?, 'Object')).to be true
      end

      it 'returns true for Object, Object' do
        expect(validator.send(:fallback_union?, 'Object, Object')).to be true
      end

      it 'returns true for FALLBACK_TYPE' do
        expect(validator.send(:fallback_union?, 'FALLBACK_TYPE')).to be true
      end

      it 'returns true for untyped' do
        expect(validator.send(:fallback_union?, 'untyped')).to be true
      end

      it 'returns false for String, Object' do
        expect(validator.send(:fallback_union?, 'String, Object')).to be false
      end

      it 'returns false for String' do
        expect(validator.send(:fallback_union?, 'String')).to be false
      end

      it 'returns false for nil' do
        expect(validator.send(:fallback_union?, nil)).to be false
      end

      it 'returns false for empty string' do
        expect(validator.send(:fallback_union?, '')).to be false
      end
    end

    it 'treats fallback union as not mismatched for any yard', :aggregate_failures do
      expect(validator.mismatched_return?('String', 'Object, Object')).to be false
      expect(validator.mismatched_return?('Hash', 'FALLBACK_TYPE, Object')).to be false
    end

    it 'handles optional ? normalization', :aggregate_failures do
      expect(validator.mismatched_return?('String?', 'String')).to be false
      expect(validator.mismatched_return?('String', 'String?')).to be false
      expect(validator.mismatched_return?('Hash?', 'Hash')).to be false
    end
  end

  describe 'void compatibility' do
    it 'treats void yard with fallback expected as not mismatched', :aggregate_failures do
      expect(validator.mismatched_return?('void', 'Object')).to be false
      expect(validator.mismatched_return?('void', 'nil')).to be false
      expect(validator.mismatched_return?('void', 'void')).to be false
      expect(validator.mismatched_return?('void', 'Object, Object')).to be false
    end

    it 'treats void mismatch with concrete expected as true', :aggregate_failures do
      expect(validator.mismatched_return?('void', 'String')).to be true
      expect(validator.mismatched_return?('void', 'Integer')).to be true
    end
  end

  describe 'yard in expected union' do
    it 'treats yard type included in expected union as not mismatched', :aggregate_failures do
      expect(validator.mismatched_return?('String', 'String, Integer')).to be false
      expect(validator.mismatched_return?('nil', 'String, nil')).to be false
      expect(validator.mismatched_return?('Boolean', 'Object, Boolean')).to be false
    end

    it 'reverse union also compatible (expected in yard)', :aggregate_failures do
      expect(validator.mismatched_return?('String, nil', 'String')).to be false
      expect(validator.mismatched_return?('String, nil', 'nil')).to be false
    end

    it 'detects true mismatch when not in union' do
      expect(validator.mismatched_return?('Float', 'String, Integer')).to be true
    end

    it 'handles Parser::AST::Node vs nil special case', :aggregate_failures do
      expect(validator.mismatched_return?('Parser::AST::Node', 'nil')).to be false
      expect(validator.mismatched_return?('nil', 'Parser::AST::Node')).to be false
    end
  end

  describe 'normalize edge cases' do
    it 'squeezes spaces and strips', :aggregate_failures do
      expect(validator.mismatched_return?('  String  ', 'String')).to be false
      expect(validator.mismatched_return?('Hash< Symbol,  String >', 'Hash<Symbol, String>')).to be true
      expect(validator.send(:normalize, '  String   ')).to eq('String')
      expect(validator.send(:normalize, 'Hash[Symbol,  String]')).to eq('Hash<Symbol, String>')
    end

    it 'handles untyped and FALLBACK_TYPE conversion', :aggregate_failures do
      expect(validator.send(:normalize, 'Hash[Symbol, untyped]')).to eq('Hash<Symbol, Object>')
      expect(validator.send(:normalize, 'FALLBACK_TYPE')).to eq('Object')
    end

    it 'converts brackets consistently', :aggregate_failures do
      expect(validator.send(:normalize, 'Array[Integer]')).to eq('Array<Integer>')
      expect(validator.send(:normalize, 'Hash[Symbol, String]')).to eq('Hash<Symbol, String>')
    end
  end

  describe 'invalid syntax' do
    it 'detects Sym bol as invalid' do
      expect(validator.invalid_syntax?('Sym bol')).to be true
    end

    it 'passes valid generics', :aggregate_failures do
      expect(validator.invalid_syntax?('Array<String>')).to be false
      expect(validator.invalid_syntax?('Hash<Symbol, Object>')).to be false
    end

    it 'returns false for nil or empty', :aggregate_failures do
      expect(validator.invalid_syntax?(nil)).to be false
      expect(validator.invalid_syntax?('')).to be false
      expect(validator.invalid_syntax?('   ')).to be false
    end

    it 'detects unbalanced brackets', :aggregate_failures do
      expect(validator.invalid_syntax?('Array<String')).to be true
      expect(validator.invalid_syntax?('Hash<Symbol, String>>')).to be true
    end

    it 'detects artefacts ,, <> ,]', :aggregate_failures do
      expect(validator.invalid_syntax?('String,, Integer')).to be true
      expect(validator.invalid_syntax?('Array<>')).to be true
      expect(validator.invalid_syntax?('Hash<Symbol,, String>')).to be true
    end
  end

  describe 'check_return and check_param source field' do
    let(:invalid_yard_type) { 'Sym bol' }

    context 'when return has invalid syntax' do
      subject(:validation_result) { validator.check_return(invalid_yard_type, 'String') }

      it 'sets source to syntax', :aggregate_failures do
        expect(validation_result.source).to eq('syntax')
        expect(validation_result.type).to eq(:invalid_syntax)
      end

      it 'includes yard in message' do
        expect(validation_result.message).to include(invalid_yard_type)
      end
    end

    context 'when return types mismatch without RBS' do
      subject(:validation_result) { validator.check_return('Integer', 'String') }

      it 'sets source to infer', :aggregate_failures do
        expect(validation_result.source).to eq('infer')
        expect(validation_result.type).to eq(:type_mismatch_return)
      end
    end

    context 'when explicit rbs source override' do
      subject(:validation_result) { validator.check_return('Integer', 'String', source: 'rbs') }

      it 'sets source to rbs' do
        expect(validation_result.source).to eq('rbs')
      end
    end

    context 'when param has invalid syntax' do
      subject(:validation_result) { validator.check_param('x', invalid_yard_type, 'String') }

      it 'sets source to syntax', :aggregate_failures do
        expect(validation_result.source).to eq('syntax')
        expect(validation_result.type).to eq(:invalid_syntax)
      end

      it 'includes yard and param in message' do
        expect(validation_result.message).to include('x').and include(invalid_yard_type)
      end
    end

    context 'when param types mismatch' do
      subject(:validation_result) { validator.check_param('x', 'String', 'Integer') }

      it 'sets source to infer', :aggregate_failures do
        expect(validation_result.source).to eq('infer')
        expect(validation_result.type).to eq(:type_mismatch_param)
      end
    end

    context 'when param with explicit rbs source' do
      subject(:validation_result) { validator.check_param('x', 'String', 'Integer', source: 'rbs') }

      it 'sets source to rbs' do
        expect(validation_result.source).to eq('rbs')
      end
    end

    context 'when param mismatch message' do
      subject(:validation_result) { validator.check_param('my_arg', 'String', 'Integer') }

      it 'includes param name and types', :aggregate_failures do
        expect(validation_result.message).to include('my_arg')
        expect(validation_result.message).to include('String').and include('Integer')
      end
    end

    it 'returns nil when no mismatch', :aggregate_failures do
      expect(validator.check_return('String', 'String')).to be_nil
      expect(validator.check_param('x', 'String', 'String')).to be_nil
    end

    it 'returns nil when yard is nil', :aggregate_failures do
      expect(validator.check_return(nil, 'String')).to be_nil
      expect(validator.check_param('x', nil, 'String')).to be_nil
    end

    it 'silences when expected is fallback', :aggregate_failures do
      expect(validator.check_return('String', 'Object')).to be_nil
      expect(validator.check_param('x', 'String', 'Object')).to be_nil
    end
  end

  describe 'custom fallback type' do
    let(:custom_validator) { described_class.new(fallback_type: 'String') }

    it 'silences when expected equals custom fallback', :aggregate_failures do
      expect(custom_validator.mismatched_return?('Integer', 'String')).to be false
      expect(custom_validator.mismatched_return?('String', 'String')).to be false
    end

    it 'detects mismatch when expected is not custom fallback' do
      expect(custom_validator.mismatched_return?('Integer', 'Float')).to be true
    end

    it 'fallback_union respects custom fallback', :aggregate_failures do
      expect(custom_validator.send(:fallback_union?, 'String')).to be true
      expect(custom_validator.send(:fallback_union?, 'String, String')).to be true
      expect(custom_validator.send(:fallback_union?, 'Object')).to be false
    end
  end
end

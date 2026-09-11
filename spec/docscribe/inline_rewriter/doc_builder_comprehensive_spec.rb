# frozen_string_literal: true

require 'docscribe/inline_rewriter/doc_builder'

RSpec.describe Docscribe::InlineRewriter::DocBuilder do
  describe '.generic_compatible?' do
    it 'treats generic Hash as compatible with detailed Hash', :aggregate_failures do
      expect(described_class.send(:generic_compatible?, 'Hash', 'Hash<Symbol, String>')).to be true
      expect(described_class.send(:generic_compatible?, 'Hash<Symbol, String>', 'Hash')).to be true
    end

    it 'treats RBS Hash[Symbol, String] as compatible with Hash', :aggregate_failures do
      expect(described_class.send(:generic_compatible?, 'Hash', 'Hash[Symbol, String]')).to be true
      expect(described_class.send(:generic_compatible?, 'Hash[Symbol, String]', 'Hash')).to be true
    end

    it 'detects mismatch for differing detailed Hash' do
      expect(described_class.send(:generic_compatible?, 'Hash<Symbol, String>', 'Hash<Symbol, Integer>')).to be false
    end

    it 'handles opts alias vs Hash', :aggregate_failures do
      expect(described_class.send(:generic_compatible?, 'Docscribe::CLI::Formatters::opts', 'Hash')).to be true
      expect(described_class.send(:generic_compatible?, 'Hash', 'Docscribe::CLI::Formatters::opts')).to be true
      expect(described_class.send(:generic_compatible?, 'Docscribe::CLI::Formatters::opts', 'Hash<Symbol, String>')).to be true
    end

    it 'handles parseInfo/setup alias vs Hash', :aggregate_failures do
      expect(described_class.send(:generic_compatible?, 'Docscribe::InlineRewriter::DocBuilder::parseInfo', 'Hash')).to be true
      expect(described_class.send(:generic_compatible?, 'Hash', 'Docscribe::InlineRewriter::DocBuilder::parseInfo')).to be true
      expect(described_class.send(:generic_compatible?, 'Docscribe::InlineRewriter::DocBuilder::setup', 'Hash')).to be true
    end

    it 'handles tuple vs Array', :aggregate_failures do
      expect(described_class.send(:generic_compatible?, '(String, Integer)', 'Array')).to be true
      expect(described_class.send(:generic_compatible?, 'Array', '(String, Integer)')).to be true
      expect(described_class.send(:generic_compatible?, '(String, Integer)', 'Hash')).to be false
    end

    it 'handles Parser::AST::Node vs nil', :aggregate_failures do
      expect(described_class.send(:generic_compatible?, 'Parser::AST::Node', 'nil')).to be true
      expect(described_class.send(:generic_compatible?, 'nil', 'Parser::AST::Node')).to be true
    end

    it 'handles optional ? normalization', :aggregate_failures do
      expect(described_class.send(:generic_compatible?, 'String?', 'String')).to be true
      expect(described_class.send(:generic_compatible?, 'String', 'String?')).to be true
    end

    it 'handles fallback union via Object', :aggregate_failures do
      expect(described_class.send(:generic_compatible?, 'Object, Object', 'Object')).to be true
      expect(described_class.send(:generic_compatible?, 'String', 'String')).to be true
    end
  end

  describe '.void_compatible?' do
    it 'treats void with fallback as compatible', :aggregate_failures do
      expect(described_class.send(:void_compatible?, 'void', 'Object', 'Object')).to be true
      expect(described_class.send(:void_compatible?, 'void', 'nil', 'Object')).to be true
      expect(described_class.send(:void_compatible?, 'void', 'void', 'Object')).to be true
      expect(described_class.send(:void_compatible?, 'void', 'Object, Object', 'Object')).to be true
    end

    it 'treats void with concrete as not compatible' do
      expect(described_class.send(:void_compatible?, 'void', 'String', 'Object')).to be false
    end
  end

  describe '.yard_in_expected_union?' do
    it 'detects yard in expected union', :aggregate_failures do
      expect(described_class.send(:yard_in_expected_union?, 'String', 'String, Integer')).to be true
      expect(described_class.send(:yard_in_expected_union?, 'nil', 'String, nil')).to be true
    end

    it 'returns false when not in union' do
      expect(described_class.send(:yard_in_expected_union?, 'Float', 'String, Integer')).to be false
    end
  end

  describe '.fallback_union?' do
    it 'detects union of only fallback', :aggregate_failures do
      expect(described_class.send(:fallback_union?, 'Object', 'Object')).to be true
      expect(described_class.send(:fallback_union?, 'Object, Object', 'Object')).to be true
      expect(described_class.send(:fallback_union?, 'String', 'Object')).to be false
      expect(described_class.send(:fallback_union?, '', 'Object')).to be false
      expect(described_class.send(:fallback_union?, nil, 'Object')).to be false
    end
  end

  describe '.normalize_type' do
    it 'converts RBS [] to YARD <>', :aggregate_failures do
      expect(described_class.send(:normalize_type, 'Hash[Symbol, String]')).to eq('Hash<Symbol, String>')
      expect(described_class.send(:normalize_type, 'Array[Integer]')).to eq('Array<Integer>')
    end

    it 'converts untyped and FALLBACK_TYPE to Object', :aggregate_failures do
      expect(described_class.send(:normalize_type, 'Hash[Symbol, untyped]')).to eq('Hash<Symbol, Object>')
      expect(described_class.send(:normalize_type, 'FALLBACK_TYPE')).to eq('Object')
    end

    it 'squeezes spaces and strips' do
      expect(described_class.send(:normalize_type, '  String  ')).to eq('String')
    end
  end

  describe '.mismatched_return?' do
    subject(:mismatched) { described_class.send(:mismatched_return?, call_context) }

    let(:config) { Docscribe::Config.new }

    context 'when yard equals expected' do
      let(:call_context) { { info: { return_type: 'String' }, normal_type: 'String', config: config } }

      it { is_expected.to be false }
    end

    context 'when yard differs and expected not fallback' do
      let(:call_context) { { info: { return_type: 'Integer' }, normal_type: 'String', config: config } }

      it { is_expected.to be true }
    end

    context 'when expected is fallback Object' do
      let(:call_context) { { info: { return_type: 'String' }, normal_type: 'Object', config: config } }

      it { is_expected.to be false }
    end

    context 'when generic compatible' do
      let(:call_context) { { info: { return_type: 'Hash' }, normal_type: 'Hash<Symbol, String>', config: config } }

      it { is_expected.to be false }
    end

    context 'when void compatible' do
      let(:call_context) { { info: { return_type: 'void' }, normal_type: 'Object', config: config } }

      it { is_expected.to be false }
    end
  end

  describe '.param_type_changed?' do
    subject(:changed) { described_class.send(:param_type_changed?, param_name, new_type, call_context) }

    let(:config) { Docscribe::Config.new }
    let(:param_name) { 'x' }

    context 'when yard vs new differ and not generic compatible' do
      let(:new_type) { 'Integer' }
      let(:call_context) { { info: { param_types: { 'x' => 'String' } }, config: config } }

      it { is_expected.to be true }
    end

    context 'when same' do
      let(:new_type) { 'String' }
      let(:call_context) { { info: { param_types: { 'x' => 'String' } }, config: config } }

      it { is_expected.to be false }
    end

    context 'when generic compatible' do
      let(:new_type) { 'Hash<Symbol, String>' }
      let(:call_context) { { info: { param_types: { 'x' => 'Hash' } }, config: config } }

      it { is_expected.to be false }
    end

    context 'when yard missing' do
      let(:new_type) { 'String' }
      let(:call_context) { { info: { param_types: {} }, config: config } }

      it { is_expected.to be false }
    end
  end

  describe 'validate_types integration for doc_builder' do
    context 'when YARD return mismatches inferred type with validate_types enabled' do
      subject(:result) { Docscribe::InlineRewriter.rewrite_with_report(code, strategy: :safe, config: config, file: 'test.rb') }

      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end
      let(:change) { result[:changes].find { |entry| entry[:type] == :updated_return } }
      let(:config) { Docscribe::Config.new('validate_types' => true) }

      it 'reports updated_return via safe mode' do
        expect(change).not_to be_nil
      end

      it 'reports infer source for updated_return' do
        expect(change[:source]).to eq('infer')
      end
    end

    context 'when YARD return is invalid syntax without validate_types' do
      subject(:result) { Docscribe::InlineRewriter.rewrite_with_report(code, strategy: :safe, config: config, file: 'test.rb') }

      let(:code) do
        <<~RUBY
          class Foo
            # @return [Sym bol]
            def bar
              :x
            end
          end
        RUBY
      end
      let(:change) { result[:changes].find { |entry| entry[:type] == :invalid_type } }
      let(:config) { Docscribe::Config.new('validate_types' => false) }

      it 'reports invalid_type with syntax source even without validate_types', :aggregate_failures do
        expect(change).not_to be_nil
        expect(change[:source]).to eq('syntax')
        expect(result[:output]).to include('@return [Symbol]')
      end
    end

    context 'when YARD return is generic compatible with inferred' do
      subject(:result) { Docscribe::InlineRewriter.rewrite_with_report(code, strategy: :safe, config: config, file: 'test.rb') }

      let(:code) do
        <<~RUBY
          class Foo
            # @return [Hash]
            def bar
              { a: 1 }
            end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('validate_types' => true) }

      it 'does not report updated when types are generic compatible' do
        expect(result[:changes].none? { |entry| entry[:type] == :updated_return }).to be true
      end
    end
  end
end

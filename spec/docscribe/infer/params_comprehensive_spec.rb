# frozen_string_literal: true

require 'docscribe/infer/params'
require 'docscribe/infer/constants'

RSpec.describe Docscribe::Infer::Params do
  describe '.infer_param_type' do
    context 'when param has splat or block prefix' do
      it 'returns Hash for **kwargs', :aggregate_failures do
        expect(described_class.infer_param_type('**kwargs', nil)).to eq('Hash')
        expect(described_class.infer_param_type('**options', nil)).to eq('Hash')
      end

      it 'returns Array for *args', :aggregate_failures do
        expect(described_class.infer_param_type('*args', nil)).to eq('Array')
        expect(described_class.infer_param_type('*rest', nil)).to eq('Array')
      end

      it 'returns Proc for &block', :aggregate_failures do
        expect(described_class.infer_param_type('&block', nil)).to eq('Proc')
        expect(described_class.infer_param_type('&blk', nil)).to eq('Proc')
      end
    end

    context 'when param has literal default value' do
      it 'infers Integer from default 123' do
        expect(described_class.infer_param_type('x', '123')).to eq('Integer')
      end

      it 'infers String from default "hi"' do
        expect(described_class.infer_param_type('x', '"hi"')).to eq('String')
      end

      it 'infers Boolean from true/false', :aggregate_failures do
        expect(described_class.infer_param_type('flag', 'true')).to eq('Boolean')
        expect(described_class.infer_param_type('flag', 'false')).to eq('Boolean')
      end

      it 'infers Hash from {} default', :aggregate_failures do
        expect(described_class.infer_param_type('opts', '{}')).to eq('Hash')
        expect(described_class.infer_param_type('options', '{ a: 1 }')).to eq('Hash')
      end

      it 'infers Array from [] default' do
        expect(described_class.infer_param_type('arr', '[]')).to eq('Array')
      end
    end

    context 'when param has no default and no prefix' do
      it 'returns Object for unknown without default' do
        expect(described_class.infer_param_type('x', nil)).to eq('Object')
      end
    end

    context 'when param is required keyword' do
      it 'returns Hash for options: without default when treat_options_keyword_as_hash true' do
        expect(described_class.infer_param_type('options:', nil, treat_options_keyword_as_hash: true)).to eq('Hash')
      end

      it 'returns Object for other required keyword without default', :aggregate_failures do
        expect(described_class.infer_param_type('kw:', nil)).to eq('Object')
        expect(described_class.infer_param_type('name:', nil)).to eq('Object')
      end

      it 'ignores treat_options when false' do
        expect(described_class.infer_param_type('options:', nil, treat_options_keyword_as_hash: false)).to eq('Object')
      end
    end
  end

  describe '.prefix_param_type' do
    it 'returns Array for *args' do
      expect(described_class.send(:prefix_param_type, '*args')).to eq('Array')
    end

    it 'returns Hash for **kwargs' do
      expect(described_class.send(:prefix_param_type, '**kwargs')).to eq('Hash')
    end

    it 'returns Proc for &block' do
      expect(described_class.send(:prefix_param_type, '&block')).to eq('Proc')
    end

    it 'returns nil for normal param', :aggregate_failures do
      expect(described_class.send(:prefix_param_type, 'x')).to be_nil
      expect(described_class.send(:prefix_param_type, 'options')).to be_nil
    end
  end

  describe 'FALLBACK_TYPE handling via infer_param_type fallback' do
    let(:custom_fallback) { 'String' }

    it 'uses custom fallback_type' do
      expect(described_class.infer_param_type('x', nil, fallback_type: custom_fallback)).to eq('String')
    end

    context 'when unknown param uses custom fallback' do
      subject(:inferred_with_custom) { described_class.infer_param_type('unknown', 'unknown_code', fallback_type: custom_type) }

      let(:fallback_alias) { 'FALLBACK_TYPE' }
      let(:inferred_with_alias) { described_class.infer_param_type('y', nil, fallback_type: fallback_alias) }
      let(:custom_type) { 'MyFallback' }

      it 'returns custom fallback for unknown_code' do
        expect(inferred_with_custom).to eq(custom_type)
      end

      it 'returns fallback alias when configured' do
        expect(inferred_with_alias).to eq(fallback_alias)
      end
    end
  end
end

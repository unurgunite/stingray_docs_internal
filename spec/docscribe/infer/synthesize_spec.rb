# frozen_string_literal: true

require 'docscribe/infer'

RSpec.describe Docscribe::Infer::Returns do
  describe 'synthesize_shovel_type' do
    subject { described_class.send(:synthesize_shovel_type, recv_type, elem_type, fallback: fallback) }

    let(:fallback) { 'Object' }

    context 'when Array << Integer' do
      let(:recv_type) { 'Array' }
      let(:elem_type) { 'Integer' }

      it { is_expected.to eq('Array<Integer>') }
    end

    context 'when Array<String> << String' do
      let(:recv_type) { 'Array<String>' }
      let(:elem_type) { 'String' }

      it { is_expected.to eq('Array<String>') }
    end

    context 'when String << String' do
      let(:recv_type) { 'String' }
      let(:elem_type) { 'String' }

      it { is_expected.to eq('String') }
    end
  end
end

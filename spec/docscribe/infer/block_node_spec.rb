# frozen_string_literal: true

require 'docscribe/infer'

RSpec.describe Docscribe::Infer::Returns do
  describe 'handle_block_node dynamic for map/then' do
    subject { described_class.infer_return_type(code) }

    context 'when [1,2].map { |x| x.to_s }' do
      let(:code) { 'def foo; [1,2].map { |x| x.to_s }; end' }

      it { is_expected.to eq('Array<String>') }
    end

    context 'when tags params map via or/begin' do
      let(:code) { File.read('lib/docscribe/cli/rbs_gen.rb')[/def build_param_strs.*?^ {8}end/m] }

      it { is_expected.to eq('Array<String>') }
    end

    context 'when rbs_output_path via then -> File.join' do
      let(:code) { File.read('lib/docscribe/cli/rbs_gen.rb')[/def rbs_output_path.*?^ {8}end/m] }

      it { is_expected.to eq('String') }
    end
  end
end

# frozen_string_literal: true

require 'docscribe/infer'

RSpec.describe Docscribe::Infer::Returns do
  describe '.shovel_method?' do
    it 'returns true for Array#<< via RBS self' do
      expect(described_class.send(:shovel_method?, 'Array', :<<, nil)).to be true
      expect(described_class.send(:shovel_method?, 'Array<String>', :<<, nil)).to be true
    end

    it 'returns true for String#<< and String#concat via RBS self' do
      expect(described_class.send(:shovel_method?, 'String', :<<, nil)).to be true
      expect(described_class.send(:shovel_method?, 'String', :concat, nil)).to be true
    end

    it 'returns true for Array#push via RBS self' do
      expect(described_class.send(:shovel_method?, 'Array', :push, nil)).to be true
    end

    it 'returns false for Array#+ (not shovel, returns Array)' do
      expect(described_class.send(:shovel_method?, 'Array', :+, nil)).to be false
      expect(described_class.send(:shovel_method?, 'Array', :-, nil)).to be false
    end

    it 'returns false for Integer#+ (not shovel)' do
      expect(described_class.send(:shovel_method?, 'Integer', :+, nil)).to be false
    end
  end

  describe 'synthesize_shovel_type' do
    it 'synthesizes Array<Integer> for a = []; a << 1' do
      expect(described_class.send(:synthesize_shovel_type, 'Array', 'Integer', fallback: 'Object')).to eq('Array<Integer>')
    end

    it 'synthesizes Array<String> for Array<String> << String' do
      expect(described_class.send(:synthesize_shovel_type, 'Array<String>', 'String', fallback: 'Object')).to eq('Array<String>')
    end

    it 'returns String for String << String (self)' do
      expect(described_class.send(:synthesize_shovel_type, 'String', 'String', fallback: 'Object')).to eq('String')
    end
  end

  describe 'handle_block_node dynamic for map/then' do
    it 'infers Array<String> for [1,2].map { |x| x.to_s } without RBS' do
      code = 'def foo; [1,2].map { |x| x.to_s }; end'
      expect(described_class.infer_return_type(code)).to eq('Array<String>')
    end

    it 'infers Array<String> for (tags&.params || []).map via dynamic or/begin' do
      code = File.read('lib/docscribe/cli/rbs_gen.rb')[/def build_param_strs.*?^        end/m]
      expect(described_class.infer_return_type(code)).to eq('Array<String>')
    end

    it 'infers String for rbs_output_path via then -> File.join' do
      code = File.read('lib/docscribe/cli/rbs_gen.rb')[/def rbs_output_path.*?^        end/m]
      expect(described_class.infer_return_type(code)).to eq('String')
    end
  end
end

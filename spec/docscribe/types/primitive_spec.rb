# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'docscribe/types/primitive'

RSpec.describe Docscribe::Types::Primitive do
  describe '.primitive?' do
    subject { described_class.primitive?(type) }

    context 'when String' do
      let(:type) { 'String' }

      it { is_expected.to be true }
    end

    context 'when Integer' do
      let(:type) { 'Integer' }

      it { is_expected.to be true }
    end

    context 'when Array' do
      let(:type) { 'Array' }

      it { is_expected.to be true }
    end

    context 'when Hash' do
      let(:type) { 'Hash' }

      it { is_expected.to be true }
    end

    context 'when untyped' do
      let(:type) { 'untyped' }

      it { is_expected.to be true }
    end

    context 'when void' do
      let(:type) { 'void' }

      it { is_expected.to be true }
    end

    context 'when nil' do
      let(:type) { 'nil' }

      it { is_expected.to be true }
    end

    context 'when Elem' do
      let(:type) { 'Elem' }

      it { is_expected.to be false }
    end

    context 'when U' do
      let(:type) { 'U' }

      it { is_expected.to be false }
    end

    context 'when V' do
      let(:type) { 'V' }

      it { is_expected.to be false }
    end

    context 'when ParamTag' do
      let(:type) { 'ParamTag' }

      it { is_expected.to be false }
    end

    context 'when Docscribe::CLI::RbsGen::ParamTag' do
      let(:type) { 'Docscribe::CLI::RbsGen::ParamTag' }

      it { is_expected.to be false }
    end

    context 'when MyCustom::MyType' do
      let(:type) { 'MyCustom::MyType' }

      it { is_expected.to be false }
    end

    context 'when String?' do
      let(:type) { 'String?' }

      it { is_expected.to be true }
    end

    context 'when Array<String>' do
      let(:type) { 'Array<String>' }

      it { is_expected.to be true }
    end

    context 'when Elem?' do
      let(:type) { 'Elem?' }

      it { is_expected.to be false }
    end
  end

  describe '.alias_token?' do
    subject { described_class.alias_token?(type) }

    context 'when Elem' do
      let(:type) { 'Elem' }

      it { is_expected.to be true }
    end

    context 'when U' do
      let(:type) { 'U' }

      it { is_expected.to be true }
    end

    context 'when my_alias' do
      let(:type) { 'my_alias' }

      it { is_expected.to be true }
    end

    context 'when Docscribe::CLI::RbsGen::ParamTag' do
      let(:type) { 'Docscribe::CLI::RbsGen::ParamTag' }

      it { is_expected.to be true }
    end

    context 'when String' do
      let(:type) { 'String' }

      it { is_expected.to be false }
    end

    context 'when Array<String>' do
      let(:type) { 'Array<String>' }

      it { is_expected.to be false }
    end

    context 'when untyped' do
      let(:type) { 'untyped' }

      it { is_expected.to be false }
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

  describe 'without the rbs gem installed' do
    let(:memo_state) { {} }

    before do
      memo_state[:had_cached] = described_class.instance_variable_defined?(:@core_primitives)
      if memo_state[:had_cached]
        memo_state[:old] = described_class.instance_variable_get(:@core_primitives)
        described_class.remove_instance_variable(:@core_primitives)
      end
      hide_const('RBS')
      allow(described_class).to receive(:require).and_call_original
      allow(described_class).to receive(:require).with('rbs').and_raise(LoadError, 'mocked missing rbs')
    end

    after do
      if memo_state[:had_cached]
        described_class.instance_variable_set(:@core_primitives, memo_state[:old])
      elsif described_class.instance_variable_defined?(:@core_primitives)
        described_class.remove_instance_variable(:@core_primitives)
      end
    end

    it 'falls back to the hardcoded list', :aggregate_failures do
      expect(described_class.primitive?('String')).to be(true)
      expect(described_class.alias_token?('Elem')).to be(true)
      expect(described_class.primitive?('Exception')).to be(false)
    end
  end

  describe 'loading without rbs' do
    let(:no_rbs_loader) do
      <<~RUBY
        $LOAD_PATH.unshift('lib')
        module Kernel
          alias_method :orig_require_for_docscribe_test, :require
          def require(name)
            raise LoadError, 'mocked missing rbs' if name == 'rbs'
            orig_require_for_docscribe_test(name)
          end
        end
        require 'docscribe'
        puts Docscribe::Types::Primitive.primitive?('String')
      RUBY
    end
    let(:project_root) { File.expand_path('../../..', __dir__) }

    it 'loads docscribe without the rbs gem', :aggregate_failures do
      out, status = Open3.capture2e(RbConfig.ruby, '-e', no_rbs_loader, chdir: project_root)
      expect(status.success?).to be(true)
      expect(out.lines.last.to_s.strip).to eq('true')
    end
  end
end

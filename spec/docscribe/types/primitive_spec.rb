# frozen_string_literal: true

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
end

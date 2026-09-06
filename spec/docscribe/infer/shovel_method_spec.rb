# frozen_string_literal: true

require 'docscribe/infer'

RSpec.describe Docscribe::Infer::Returns do
  describe '.shovel_method?' do
    subject { described_class.send(:shovel_method?, recv_type, meth, provider) }

    let(:provider) { nil }

    context 'when Array#<<' do
      let(:recv_type) { 'Array' }
      let(:meth) { :<< }

      it { is_expected.to be true }
    end

    context 'when Array<String>#<<' do
      let(:recv_type) { 'Array<String>' }
      let(:meth) { :<< }

      it { is_expected.to be true }
    end

    context 'when String#<<' do
      let(:recv_type) { 'String' }
      let(:meth) { :<< }

      it { is_expected.to be true }
    end

    context 'when String#concat' do
      let(:recv_type) { 'String' }
      let(:meth) { :concat }

      it { is_expected.to be true }
    end

    context 'when Array#push' do
      let(:recv_type) { 'Array' }
      let(:meth) { :push }

      it { is_expected.to be true }
    end

    context 'when Array#+ (not shovel)' do
      let(:recv_type) { 'Array' }
      let(:meth) { :+ }

      it { is_expected.to be false }
    end

    context 'when Array#- (not shovel)' do
      let(:recv_type) { 'Array' }
      let(:meth) { :- }

      it { is_expected.to be false }
    end

    context 'when Integer#+ (not shovel)' do
      let(:recv_type) { 'Integer' }
      let(:meth) { :+ }

      it { is_expected.to be false }
    end
  end
end

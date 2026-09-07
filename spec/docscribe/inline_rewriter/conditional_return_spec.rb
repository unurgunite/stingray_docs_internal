# frozen_string_literal: true

require 'docscribe/inline_rewriter'
require 'docscribe/inline_rewriter/doc_builder'

RSpec.describe Docscribe::InlineRewriter::DocBuilder do
  describe 'conditional @return extraction' do
    subject(:info) { { has_return: false, return_type: nil, return_description: nil } }

    it 'keeps main void when conditional Object follows' do
      described_class.send(:extract_return_info, '# @return [void]', info)
      described_class.send(:extract_return_info, '# @return [Object] if StandardError', info)
      expect(info[:return_type]).to eq('void')
    end

    it 'keeps main return description, not the conditional one' do
      described_class.send(:extract_return_info, '# @return [void] does work', info)
      described_class.send(:extract_return_info, '# @return [Object] if StandardError', info)
      expect(info[:return_description]).to eq('does work')
    end

    it 'leaves type nil for conditional-only docs but marks has_return' do
      described_class.send(:extract_return_info, '# @return [Object] if StandardError', info)
      expect(info[:has_return]).to be(true)
      expect(info[:return_type]).to be_nil
    end

    it 'detects conditional descriptions', :aggregate_failures do
      expect(described_class.send(:conditional_return_desc?, 'if StandardError')).to be(true)
      expect(described_class.send(:conditional_return_desc?, 'does work')).to be(false)
      expect(described_class.send(:conditional_return_desc?, nil)).to be(false)
    end
  end

  describe 'fallback rescue types are not emitted' do
    subject(:lines) { described_class.send(:build_rescue_return_lines, '# ', specs, conf) }

    let(:conf) { Docscribe::Config.new('emit' => { 'rescue_conditional_returns' => true }) }

    context 'when rescue type is bare Object fallback' do
      let(:specs) { [[%w[StandardError], 'Object']] }

      it { is_expected.to eq([]) }
    end

    context 'when rescue type is blank' do
      let(:specs) { [[%w[StandardError], '']] }

      it { is_expected.to eq([]) }
    end

    context 'when rescue type is informative' do
      let(:specs) { [[%w[StandardError], 'String']] }

      it { is_expected.to eq(['# # @return [String] if StandardError']) }
    end

    context 'when rescue type is nil' do
      let(:specs) { [[%w[StandardError], 'nil']] }

      it { is_expected.to eq(['# # @return [nil] if StandardError']) }
    end
  end

  describe 'check stability with conditional present' do
    subject(:messages) { report[:changes].map { |c| c[:message] } }

    let(:report) { Docscribe::InlineRewriter.rewrite_with_report(code) }

    let(:code) do
      <<~RUBY
        class Foo
          # @param [String] key lookup key
          # @return [String]
          # @return [Integer] if StandardError
          def get(key)
            "value"
          rescue StandardError
            0
          end
        end
      RUBY
    end

    it 'does not report updated @return from the conditional type' do
      expect(messages.none? { |m| m.start_with?('updated @return') }).to be(true)
    end
  end
end

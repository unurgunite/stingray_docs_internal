# frozen_string_literal: true

require 'docscribe/inline_rewriter'
require 'docscribe/parsing'

RSpec.describe Docscribe::InlineRewriter do
  describe '.rewrite_with_report per-method isolation' do
    subject(:report) { described_class.rewrite_with_report(code) }

    let(:code) do
      <<~RUBY
        class Foo
          # @return [Array<String>] items
          def items(node)
            (node.children[1..] || []).compact.filter_map do |child|
              child.to_s if child.is_a?(String)
            end
          end

          # @param [String] name user name
          # @return [Integer] greeting
          def greet(name)
            "hi \#{name}"
          end
        end
      RUBY
    end

    it 'reports offenses for all methods' do
      expect(report[:changes]).not_to be_empty
    end

    context 'when one method raises during doc build' do
      before do
        allow(Docscribe::InlineRewriter::DocBuilder).to receive(:build).and_wrap_original do |original, insertion, **params|
          raise 'boom' if insertion.node.children[0] == :items

          original.call(insertion, **params)
        end
      end

      it 'still reports offenses for the other method', :aggregate_failures do
        expect(report[:changes].map { |c| c[:method] }).to include('Foo#greet')
        expect(report[:changes].map { |c| c[:method] }).not_to include('Foo#items')
      end

      it 'warns about the skipped method to stderr' do
        expect { report }.to output(/skipping method items/).to_stderr
      end
    end
  end

  describe '.insertion_label' do
    subject(:label) { described_class.send(:insertion_label, kind, ins) }

    let(:kind) { :method }

    context 'when insertion has a named node' do
      let(:node) { Docscribe::Parsing.parse("def foo\n  42\nend\n") }
      let(:ins) { Struct.new(:node).new(node) }

      it { is_expected.to eq('method foo at line 1') }
    end

    context 'when insertion has no node' do
      let(:ins) { {} }

      it { is_expected.to eq('method') }
    end
  end
end

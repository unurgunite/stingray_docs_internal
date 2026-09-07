# frozen_string_literal: true

require 'docscribe/inline_rewriter'

RSpec.describe Docscribe::InlineRewriter do
  describe 'trailing # comment inside method body' do
    subject(:messages) { report[:changes].map { |c| c[:message] }.sort }

    let(:report) { described_class.rewrite_with_report(code) }

    let(:body) do
      <<~RUBY
        class Foo
          # @return [Array<String>] items
          def items(node)
            (node.children[1..] || []).compact.filter_map do |child|
              child.to_s if child.is_a?(String)
            end#{trailer}
          end

          # @param [String] name user name
          # @return [Integer] greeting
          def greet(name)
            "hi \#{name}"
          end
        end
      RUBY
    end
    let(:code) { body }
    let(:trailer) { '' }

    context 'without trailing comment' do
      it 'reports offenses for both methods' do
        expect(messages.size).to eq(3)
      end
    end

    context 'with tight trailing # comment' do
      let(:trailer) { '#' }

      it 'reports the same offenses as without comment' do
        expect(messages.size).to eq(3)
      end

      it 'keeps the items return mismatch' do
        expect(messages).to include('updated @return from Array<String> to Array<String?>')
      end
    end

    context 'with spaced trailing comment' do
      let(:trailer) { ' # trailing note' }

      it 'reports the same offenses as without comment' do
        expect(messages.size).to eq(3)
      end
    end
  end
end

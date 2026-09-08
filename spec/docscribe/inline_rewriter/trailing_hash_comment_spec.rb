# frozen_string_literal: true

require 'docscribe/inline_rewriter'

RSpec.describe Docscribe::InlineRewriter do
  describe 'trailing # comment inside method body' do
    subject(:messages) { report[:changes].map { |c| c[:message] }.sort }

    let(:report) { described_class.rewrite_with_report(code) }
    let(:clean_messages) do
      described_class.rewrite_with_report(clean_code)[:changes].map { |c| c[:message] }.sort
    end
    let(:clean_code) { trailer.empty? ? code : code.sub("end#{trailer}", 'end') }

    let(:code) do
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
    let(:trailer) { '' }

    context 'without trailing comment' do
      it 'reports offenses' do
        expect(messages).not_to be_empty
      end
    end

    context 'with tight trailing # comment' do
      let(:trailer) { '#' }

      it 'reports the same offenses as without comment' do
        expect(messages).to eq(clean_messages)
      end
    end

    context 'with spaced trailing comment' do
      let(:trailer) { ' # trailing note' }

      it 'reports the same offenses as without comment' do
        expect(messages).to eq(clean_messages)
      end
    end
  end
end

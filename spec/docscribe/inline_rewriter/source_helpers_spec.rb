# frozen_string_literal: true

RSpec.describe Docscribe::InlineRewriter::SourceHelpers do
  describe 'contiguous doc lines above a method' do
    let(:code) do
      <<~RUBY
        module M
          # @param [Object] x Param documentation.
          # @return [Object]
          # @note module_function: when included, also defines #foo (instance visibility: private)
          def foo(x); x; end
        end
      RUBY
    end

    let(:buffer) { Parser::Source::Buffer.new('(example)', source: code) }
    let(:ast) { Docscribe::Parsing.parse_buffer(buffer) }
    let(:node) { find_first_def(ast) }

    let(:info) do
      bol = described_class.line_start_range(buffer, node)
      described_class.doc_comment_block_info(buffer, bol.begin_pos)
    end

    it 'finds the def node' do
      expect(node).not_to be_nil
    end

    it 'finds doc comment info' do
      expect(info).not_to be_nil
    end

    it 'includes trailing @note lines' do
      expect(info[:doc_lines].join).to include('@note module_function:')
    end
  end
end

# frozen_string_literal: true

require 'docscribe/inline_rewriter'

RSpec.describe Docscribe::InlineRewriter do
  describe 'preserves tab indentation when inserting docs' do
    subject(:out) { inline(code, config: config) }

    let(:code) { "class A\n\tdef foo; 1; end\nend\n" }
    let(:config) { Docscribe::Config.new('emit' => { 'header' => true }) }

    it 'uses tab indentation for header' do
      expect(out).to include("\t# +A#foo+ -> Integer")
    end
  end

  describe 'with inline modifier defs' do
    subject(:out) { inline(code, config: Docscribe::Config.new('emit' => { 'header' => true })) }

    let(:code) do
      <<~RUBY
        class A
          private def foo; 1; end
        end
      RUBY
    end

    it 'uses line indentation for inline modifier defs (private def ...)' do
      expect(out).to include('  # +A#foo+ -> Integer')
    end
  end

  describe 'when not duplicating existing @!attribute entries' do
    subject(:out) { described_class.insert_comments(code, strategy: :safe, config: conf) }

    let(:conf) { Docscribe::Config.new('emit' => { 'attributes' => true }) }

    let(:code) do
      <<~RUBY
        # @!attribute node
        #   @return [Parser::AST::Node]
        # @!attribute scope
        #   @return [Symbol]
        AttrInsertion = Struct.new(:node, :scope)
      RUBY
    end

    it 'does not duplicate existing @!attribute entries' do
      expect(out.scan(/^\s*#\s*@!attribute\b/).size).to eq(2)
    end

    it 'preserves existing @!attribute node' do
      expect(out).to include('# @!attribute node')
    end

    it 'preserves existing @!attribute scope' do
      expect(out).to include('# @!attribute scope')
    end

    it 'does not add [rw] to node' do
      expect(out).not_to include('# @!attribute [rw] node')
    end

    it 'does not add [rw] to scope' do
      expect(out).not_to include('# @!attribute [rw] scope')
    end
  end
end

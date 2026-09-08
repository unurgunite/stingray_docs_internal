# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'parser/current'
require 'docscribe/inline_rewriter/doc_builder'
require 'docscribe/types/signature'

RSpec.describe Docscribe::InlineRewriter::DocBuilder do
  describe '.build_kwrestarg_line' do
    let(:indent) { '  ' }
    let(:opts) do
      {
        fallback_type: 'Object',
        treat_options_keyword_as_hash: true,
        param_tag_style: 'type_name',
        param_documentation: 'Param documentation.'
      }
    end
    let(:code) { 'def foo(**kwargs); end' }
    let(:ast) { Parser::CurrentRuby.parse(code) }
    let(:args_node) { ast.children[1] }
    let(:kwrest_node) { args_node.children.find { |n| n.type == :kwrestarg } }

    context 'with external_sig Hash[Symbol, untyped]' do
      subject(:line) { described_class.send(:build_kwrestarg_line, kwrest_node, indent, external_sig, nil, **opts) }

      let(:external_sig) do
        Docscribe::Types::MethodSignature.new(
          return_type: 'Object',
          param_types: {},
          positional_types: [],
          rest_positional: nil,
          rest_keywords: Docscribe::Types::RestKeywords.new(name: 'kwargs', type: 'Hash[Symbol, untyped]')
        )
      end

      it 'uses external_sig rest_keywords type Hash[Symbol, untyped]' do
        expect(line).to include('[Hash[Symbol, untyped]]')
      end

      it 'includes kwargs name' do
        expect(line).to include('kwargs')
      end

      it 'includes @param tag' do
        expect(line).to include('@param')
      end

      it 'respects indent' do
        expect(line).to start_with(indent)
      end
    end

    context 'without external_sig fallback Hash' do
      subject(:line) { described_class.send(:build_kwrestarg_line, kwrest_node, indent, external_sig, nil, **opts) }

      let(:external_sig) { nil }

      it 'falls back to Hash via infer' do
        expect(line).to include('[Hash]')
      end

      it 'includes kwargs name' do
        expect(line).to include('kwargs')
      end

      it 'includes @param tag' do
        expect(line).to include('@param')
      end

      it 'does not include Hash[Symbol, untyped]' do
        expect(line).not_to include('Hash[Symbol, untyped]')
      end
    end

    context 'without external_sig and anonymous **' do
      subject(:line) { described_class.send(:build_kwrestarg_line, anon_kwrest, indent, nil, nil, **opts) }

      let(:anon_kwrest) do
        code = 'def foo(**); end'
        ast = Parser::CurrentRuby.parse(code)
        ast.children[1].children.find { |n| n.type == :kwrestarg }
      end

      it 'defaults name to kwargs' do
        expect(line).to include('kwargs')
      end

      it 'falls back to Hash' do
        expect(line).to include('[Hash]')
      end
    end

    context 'with param_types_override taking precedence over infer' do
      subject(:line) { described_class.send(:build_kwrestarg_line, kwrest_node, indent, nil, override, **opts) }

      let(:override) { { 'kwargs' => 'Hash<Symbol, String>' } }

      it 'uses override type' do
        expect(line).to include('[Hash<Symbol, String>]')
      end
    end

    context 'with external_sig precedence over override' do
      subject(:line) { described_class.send(:build_kwrestarg_line, kwrest_node, indent, external_sig, override, **opts) }

      let(:external_sig) do
        Docscribe::Types::MethodSignature.new(
          return_type: 'Object',
          param_types: {},
          positional_types: [],
          rest_positional: nil,
          rest_keywords: Docscribe::Types::RestKeywords.new(name: 'kwargs', type: 'Hash[Symbol, untyped]')
        )
      end
      let(:override) { { 'kwargs' => 'Hash<Symbol, String>' } }

      it 'prefers external_sig over override' do
        expect(line).to include('[Hash[Symbol, untyped]]')
      end
    end
  end

  describe 'inline integration for **kwargs' do
    subject(:output) { inline(code) }

    let(:code) do
      <<~RUBY
        class Demo
          def foo(**kwargs); 0; end
        end
      RUBY
    end

    it 'infers Hash for **kwargs without external sig' do
      expect(output).to include('@param [Hash] kwargs')
    end

    context 'with RBS external_sig providing Hash[Symbol, untyped]' do
      subject(:output) { inline_with_rbs(code: code, rbs: rbs) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(**kwargs); 0; end
          end
        RUBY
      end
      let(:rbs) do
        <<~RBS
          class Demo
            def foo: (**untyped) -> void
          end
        RBS
      end

      it 'falls back to Object or Hash depending on provider but does not crash', :aggregate_failures do
        expect(output).to include('@param')
        expect(output).to include('kwargs')
      end
    end
  end
end

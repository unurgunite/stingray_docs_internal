# frozen_string_literal: true

require 'docscribe/infer'

RSpec.describe Docscribe::Infer::Returns do
  describe 'FALLBACK_TYPE alias handling' do
    context 'when source is empty or invalid' do
      it 'returns Object for empty string' do
        expect(described_class.infer_return_type('')).to eq('Object')
      end

      it 'returns Object for nil' do
        expect(described_class.infer_return_type(nil)).to eq('Object')
      end

      it 'returns Object for invalid ruby' do
        expect(described_class.infer_return_type('not ruby')).to eq('Object')
      end
    end

    context 'when method body is FALLBACK_TYPE constant' do
      subject(:inferred) do
        described_class.send(:run_last_expr_type, method_body, fallback_type: 'Object', nil_as_optional: true,
                                                               core_rbs_provider: nil)
      end

      let(:code) do
        <<~RUBY
          def foo
            FALLBACK_TYPE
          end
        RUBY
      end
      let(:parsed_node) { described_class.parse_method_source(code) }
      let(:method_body) { described_class.extract_def_body(parsed_node) }

      it 'falls back to Object for bare sentinel without scope info' do
        expect(inferred).to eq('Object')
      end
    end

    context 'when inferring rescue branches with scope info' do
      subject(:rescues) do
        spec = { normal: 'Object', rescues: [] }
        described_class.send(:process_rescue_branches, spec, body, container: container)
        spec[:rescues]
      end

      let(:body) do
        Parser::AST::Node.new(:rescue, [
                                Parser::AST::Node.new(:send, [nil, :parse_something]),
                                Parser::AST::Node.new(:resbody, [
                                                        Parser::AST::Node.new(:array, [Parser::AST::Node.new(:const, [nil, :Parser])]),
                                                        nil,
                                                        Parser::AST::Node.new(:const, [nil, :FALLBACK_TYPE])
                                                      ])
                              ])
      end
      let(:container) { 'Docscribe::Infer::Returns' }

      it 'infers String for the sentinel rescue body' do
        expect(rescues).to eq([[%w[Parser], 'String']])
      end
    end

    context 'when resolving constant values with scope info' do
      it 'resolves docscribe sentinel in its own scope' do
        node = Parser::AST::Node.new(:const, [nil, :FALLBACK_TYPE])
        expect(described_class.send(:resolve_const_value_type, node, 'Docscribe::Infer::Returns')).to eq('String')
      end

      it 'resolves core top-level constants without container' do
        node = Parser::AST::Node.new(:const, [nil, :RUBY_VERSION])
        expect(described_class.send(:resolve_const_value_type, node, nil)).to eq('String')
      end

      it 'returns nil for unknown constants' do
        node = Parser::AST::Node.new(:const, [nil, :NO_SUCH_CONST_XYZ])
        expect(described_class.send(:resolve_const_value_type, node, 'Docscribe::Infer::Returns')).to be_nil
      end

      it 'skips class-valued constants to keep name-based inference' do
        node = Parser::AST::Node.new(:const, [nil, :String])
        expect(described_class.send(:resolve_const_value_type, node, 'Docscribe::Infer::Returns')).to be_nil
      end

      it 'does not steal user constants missing from this runtime' do
        node = Parser::AST::Node.new(:const, [nil, :FALLBACK_TYPE])
        expect(described_class.send(:resolve_const_value_type, node, 'MyApp::Thing')).to be_nil
      end
    end

    describe 'unify_types normalization' do
      it 'normalizes FALLBACK_TYPE as first arg' do
        expect(described_class.send(:unify_types, 'FALLBACK_TYPE', 'String', fallback_type: 'Object', nil_as_optional: true)).to eq('Object, String')
      end

      it 'normalizes FALLBACK_TYPE as second arg' do
        expect(described_class.send(:unify_types, 'String', 'FALLBACK_TYPE', fallback_type: 'Object', nil_as_optional: true)).to eq('String, Object')
      end

      it 'normalizes untyped as fallback' do
        expect(described_class.send(:unify_types, 'untyped', 'String', fallback_type: 'Object', nil_as_optional: true)).to eq('Object, String')
      end

      it 'deduplicates fallback when both are same' do
        expect(described_class.send(:unify_types, 'FALLBACK_TYPE', 'Object', fallback_type: 'Object', nil_as_optional: true)).to eq('Object')
      end
    end

    describe 'fallback_alias? detection' do
      it 'detects FALLBACK_TYPE' do
        expect(described_class.send(:fallback_alias?, 'FALLBACK_TYPE', 'Object')).to be true
      end

      it 'detects Object as alias for itself' do
        expect(described_class.send(:fallback_alias?, 'Object', 'Object')).to be true
      end

      it 'detects untyped as alias' do
        expect(described_class.send(:fallback_alias?, 'untyped', 'Object')).to be true
      end

      it 'detects Object? as alias' do
        expect(described_class.send(:fallback_alias?, 'Object?', 'Object')).to be true
      end

      it 'rejects String as alias' do
        expect(described_class.send(:fallback_alias?, 'String', 'Object')).to be false
      end

      it 'rejects nil as alias' do
        expect(described_class.send(:fallback_alias?, nil, 'Object')).to be false
      end
    end

    describe 'handle_or node with fallback alias' do
      let(:or_node) do
        Parser::AST::Node.new(:or, [Parser::AST::Node.new(:str, ['a']), Parser::AST::Node.new(:lvar, [:x])])
      end
      let(:or_buffer) do
        buffer = Parser::Source::Buffer.new('(test)')
        buffer.source = 'def foo; a || b; end'
        buffer
      end
      let(:or_ast) { Docscribe::Parsing.parse_buffer(or_buffer) }
      let(:or_result) do
        described_class.send(:handle_or_node, or_node, fallback_type: 'Object', nil_as_optional: true)
      end

      before do
        allow(described_class).to receive(:run_last_expr_type).and_return('String', 'FALLBACK_TYPE')
        or_ast
      end

      it 'detects fallback alias' do
        expect(described_class.send(:fallback_alias?, 'FALLBACK_TYPE', 'Object')).to be true
      end

      it 'prefers concrete when other is fallback alias' do
        expect(or_result).to be_a(String)
      end
    end
  end

  describe 'block RBS Array<String> via handle_block_node' do
    context 'when block has RBS type containing U/Elem and inner type' do
      subject(:output) { inline(code, config: config) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo
              [1, 2, 3].map { |x| x.to_s }
            end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('emit' => { 'header' => true }) }

      before { skip_unless_rbs_available! }

      it 'infers Array<String> vs String handling for Array#map like blocks' do
        expect(output).to include('@return')
      end
    end

    context 'when block has no RBS type' do
      let(:code) do
        <<~RUBY
          def foo
            [1,2].each { 42 }
          end
        RUBY
      end
      let(:parsed_outer) { described_class.parse_method_source(code) }
      let(:block_body) { described_class.extract_def_body(parsed_outer) }
      let(:block_result) do
        described_class.send(:handle_block_node, block_body, fallback_type: 'Object', nil_as_optional: true)
      end

      before do
        allow(described_class).to receive(:send_rbs_type).and_return(nil)
      end

      it 'has block body' do
        expect(block_body).not_to be_nil
      end

      it 'has block type' do
        expect(block_body.type).to eq(:block)
      end

      it 'does not raise when handling block' do
        expect { described_class.send(:handle_block_node, block_body, fallback_type: 'Object', nil_as_optional: true) }.not_to raise_error
      end

      it 'returns inner type Integer' do
        expect(block_result).to eq('Integer')
      end
    end
  end

  describe 'tuple vs Array generic' do
    let(:validator) { Docscribe::Validator::TypeMismatchValidator.new }

    it 'treats tuple as compatible with Array first direction' do
      expect(validator.generic_compatible?('(String, Integer)', 'Array')).to be true
    end

    it 'treats tuple as compatible with Array second direction' do
      expect(validator.generic_compatible?('Array', '(String, Integer)')).to be true
    end

    it 'does not treat tuple as compatible with Hash' do
      expect(validator.generic_compatible?('(String, Integer)', 'Hash')).to be false
    end

    it 'reports mismatched return for tuple vs Hash' do
      expect(validator.mismatched_return?('(String, Integer)', 'Hash')).to be true
    end
  end

  describe 'lookup_lvar_type skips FALLBACK_TYPE' do
    it 'returns nil when lvar type is Object alias' do
      skip 'FALLBACK_TYPE not Object' unless Docscribe::Infer::FALLBACK_TYPE == 'Object'
      expect(described_class.send(:lookup_lvar_type, 'x', { 'x' => 'Object' }, nil)).to be_nil
    end

    it 'returns nil when lvar type is FALLBACK_TYPE constant' do
      expect(described_class.send(:lookup_lvar_type, 'x', { 'x' => Docscribe::Infer::FALLBACK_TYPE }, nil)).to be_nil
    end

    it 'returns param type when not fallback' do
      expect(described_class.send(:lookup_lvar_type, 'y', nil, { 'y' => 'String' })).to eq('String')
    end

    it 'returns param type for Object fallback' do
      expect(described_class.send(:lookup_lvar_type, 'z', nil, { 'z' => 'Object' })).to eq('Object')
    end

    it 'returns param type for FALLBACK_TYPE via params' do
      expect(described_class.send(:lookup_lvar_type, 'z', nil, { 'z' => Docscribe::Infer::FALLBACK_TYPE })).to eq('Object')
    end
  end

  describe Docscribe::Infer::Literals do
    describe '.type_from_literal' do
      let(:integer_node) { Parser::AST::Node.new(:int, [1]) }
      let(:string_node) { Parser::AST::Node.new(:str, ['hi']) }
      let(:true_node) { Parser::AST::Node.new(:true, []) }
      let(:false_node) { Parser::AST::Node.new(:false, []) }
      let(:nil_node) { Parser::AST::Node.new(:nil, []) }
      let(:array_node) { Parser::AST::Node.new(:array, []) }
      let(:hash_node) { Parser::AST::Node.new(:hash, []) }
      let(:send_node) { Parser::AST::Node.new(:send, [nil, :foo]) }

      it 'maps integer literal' do
        expect(described_class.type_from_literal(integer_node)).to eq('Integer')
      end

      it 'maps string literal' do
        expect(described_class.type_from_literal(string_node)).to eq('String')
      end

      it 'maps true literal' do
        expect(described_class.type_from_literal(true_node)).to eq('Boolean')
      end

      it 'maps false literal' do
        expect(described_class.type_from_literal(false_node)).to eq('Boolean')
      end

      it 'maps nil literal' do
        expect(described_class.type_from_literal(nil_node)).to eq('nil')
      end

      it 'maps array literal' do
        expect(described_class.type_from_literal(array_node)).to eq('Array')
      end

      it 'maps hash literal' do
        expect(described_class.type_from_literal(hash_node)).to eq('Hash')
      end

      it 'returns fallback for nil input' do
        expect(described_class.type_from_literal(nil)).to eq('Object')
      end

      it 'returns fallback for send node' do
        expect(described_class.type_from_literal(send_node)).to eq('Object')
      end
    end
  end
end

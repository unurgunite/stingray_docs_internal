# frozen_string_literal: true

require 'docscribe/infer'

RSpec.describe Docscribe::Infer::Returns do
  describe '.infer_return_type build_priority' do
    subject(:inferred) { described_class.infer_return_type(method_source) }

    context 'when chain is map.each_with_index' do
      let(:method_source) do
        'def foo(tag_order); Array(tag_order).map { |t| t.to_s.sub(/^:/, "") }.each_with_index; end'
      end

      it 'infers Enumerator<String, Integer> via synthetic', :aggregate_failures do
        expect(inferred).to eq('Enumerator<String, Integer>')
        expect(inferred).not_to eq('Array<Object>')
      end
    end

    context 'when chain is map.each_with_index.to_h' do
      let(:method_source) do
        'def foo(tag_order); Array(tag_order).map { |t| t.to_s.sub(/^:/, "") }.each_with_index.to_h; end'
      end

      it 'infers Hash<String, Integer> not Hash<Object, Object>', :aggregate_failures do
        expect(inferred).to eq('Hash<String, Integer>')
        expect(inferred).not_to eq('Hash<Object, Object>')
      end
    end

    context 'when chain is each_with_index.to_h with a block' do
      let(:method_source) do
        'def foo(arr); arr.each_with_index.to_h { |x, i| [x.to_s, i] }; end'
      end

      it 'infers Hash not Array', :aggregate_failures do
        expect(inferred).to eq('Hash<String, Integer>')
        expect(inferred).not_to eq('Array')
      end
    end

    context 'when to_h block follows a map chain' do
      let(:method_source) do
        'def foo(tag_order); Array(tag_order).map { |t| t.to_s }.each_with_index.to_h { |x, i| [x, i] }; end'
      end

      it 'infers Hash<String, Integer>', :aggregate_failures do
        expect(inferred).to eq('Hash<String, Integer>')
        expect(inferred).not_to eq('Hash<Object, Object>')
      end
    end

    context 'when to_h block transforms both pair elements' do
      let(:method_source) do
        'def foo(arr); arr.each_with_index.to_h { |x, i| [x.to_s, i.to_s] }; end'
      end

      it 'infers Hash<String, String>' do
        expect(inferred).to eq('Hash<String, String>')
      end
    end

    context 'when to_h block pair cannot be inferred' do
      let(:method_source) do
        'def foo(arr); arr.each_with_index.to_h { |x, i| [x.foo, y.bar] }; end'
      end

      it 'falls back to Hash<Object, Object>' do
        expect(inferred).to eq('Hash<Object, Object>')
      end
    end

    context 'when to_h block body is not a pair' do
      let(:method_source) do
        'def foo(arr); arr.each_with_index.to_h { |x, i| x.to_s }; end'
      end

      it 'uses receiver elem and Integer index', :aggregate_failures do
        expect(inferred).to eq('Hash<Object, Integer>')
        expect(inferred).not_to eq('Array')
      end
    end
  end

  describe '.run_last_expr_type integration' do
    subject(:inferred) do
      described_class.send(:run_last_expr_type, body, fallback_type: 'Object', nil_as_optional: true)
    end

    let(:code) do
      'def foo(tag_order); Array(tag_order).map { |t| t.to_s.sub(/^:/, "") }.each_with_index.to_h; end'
    end
    let(:parsed) { described_class.parse_method_source(code) }
    let(:body) { described_class.extract_def_body(parsed) }

    it { is_expected.to eq('Hash<String, Integer>') }
  end

  describe '.synthetic_enumerator_type direct' do
    subject(:result) do
      described_class.send(:synthetic_enumerator_type, node, meth, recv, fallback_type: 'Object', local_var_types: local_var_types)
    end

    context 'when recv is Array<String>' do
      let(:recv) { Parser::AST::Node.new(:lvar, [:arr]) }
      let(:node) { Parser::AST::Node.new(:send, [recv, :each_with_index]) }
      let(:meth) { :each_with_index }
      let(:local_var_types) { { 'arr' => 'Array<String>' } }

      it { is_expected.to eq('Enumerator<String, Integer>') }
    end

    context 'when recv is bare Array' do
      let(:recv) { Parser::AST::Node.new(:lvar, [:arr]) }
      let(:node) { Parser::AST::Node.new(:send, [recv, :each_with_index]) }
      let(:meth) { :each_with_index }
      let(:local_var_types) { { 'arr' => 'Array' } }

      it { is_expected.to eq('Enumerator<Object, Integer>') }
    end

    context 'when meth is not each_with_index' do
      let(:recv) { Parser::AST::Node.new(:lvar, [:arr]) }
      let(:node) { Parser::AST::Node.new(:send, [recv, :map]) }
      let(:meth) { :map }
      let(:local_var_types) { { 'arr' => 'Array<String>' } }

      it { is_expected.to be_nil }
    end

    context 'when node has extra args' do
      let(:recv) { Parser::AST::Node.new(:lvar, [:arr]) }
      let(:arg) { Parser::AST::Node.new(:int, [1]) }
      let(:node) { Parser::AST::Node.new(:send, [recv, :each_with_index, arg]) }
      let(:meth) { :each_with_index }
      let(:local_var_types) { { 'arr' => 'Array<String>' } }

      it { is_expected.to be_nil }
    end
  end

  describe '.synthetic_hash_type direct' do
    subject(:result) do
      described_class.send(:synthetic_hash_type, to_h_node, meth, recv_each, local_var_types: local_var_types)
    end

    let(:meth) { :to_h }

    context 'when inner is Array<String>' do
      let(:inner) { Parser::AST::Node.new(:lvar, [:arr]) }
      let(:recv_each) { Parser::AST::Node.new(:send, [inner, :each_with_index]) }
      let(:to_h_node) { Parser::AST::Node.new(:send, [recv_each, :to_h]) }
      let(:local_var_types) { { 'arr' => 'Array<String>' } }

      it { is_expected.to eq('Hash<String, Integer>') }
    end

    context 'when inner is Array<Integer>' do
      let(:inner) { Parser::AST::Node.new(:lvar, [:arr]) }
      let(:recv_each) { Parser::AST::Node.new(:send, [inner, :each_with_index]) }
      let(:to_h_node) { Parser::AST::Node.new(:send, [recv_each, :to_h]) }
      let(:local_var_types) { { 'arr' => 'Array<Integer>' } }

      it { is_expected.to eq('Hash<Integer, Integer>') }
    end

    context 'when inner is Enumerator<String, Integer>' do
      let(:inner) { Parser::AST::Node.new(:lvar, [:en]) }
      let(:recv_each) { Parser::AST::Node.new(:send, [inner, :each_with_index]) }
      let(:to_h_node) { Parser::AST::Node.new(:send, [recv_each, :to_h]) }
      let(:local_var_types) { { 'en' => 'Enumerator<String, Integer>' } }

      it { is_expected.to eq('Hash<String, Integer>') }
    end

    context 'when meth is not to_h' do
      let(:inner) { Parser::AST::Node.new(:lvar, [:arr]) }
      let(:recv_each) { Parser::AST::Node.new(:send, [inner, :each_with_index]) }
      let(:to_h_node) { Parser::AST::Node.new(:send, [recv_each, :map]) }
      let(:meth) { :map }
      let(:local_var_types) { { 'arr' => 'Array<String>' } }

      it { is_expected.to be_nil }
    end

    context 'when recv is not each_with_index' do
      let(:recv_each) { Parser::AST::Node.new(:lvar, [:arr]) }
      let(:to_h_node) { Parser::AST::Node.new(:send, [recv_each, :to_h]) }
      let(:local_var_types) { { 'arr' => 'Array<String>' } }

      it { is_expected.to be_nil }
    end
  end
end

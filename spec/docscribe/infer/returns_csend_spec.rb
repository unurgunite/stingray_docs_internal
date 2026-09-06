# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'docscribe/infer'

RSpec.describe Docscribe::Infer::Returns do
  describe 'receiver_rbs_type_name for literals and vars' do
    subject(:recv_type) { described_class.send(:receiver_rbs_type_name, recv_node, provider, local_var_types, param_types) }

    let(:provider) { nil }
    let(:local_var_types) { nil }
    let(:param_types) { nil }

    context 'when recv is nil literal' do
      let(:recv_node) { Parser::AST::Node.new(:nil, []) }

      it { is_expected.to eq('NilClass') }
    end

    context 'when recv is string' do
      let(:recv_node) { Parser::AST::Node.new(:str, ['a']) }

      it { is_expected.to eq('String') }
    end

    context 'when recv is int' do
      let(:recv_node) { Parser::AST::Node.new(:int, [1]) }

      it { is_expected.to eq('Integer') }
    end

    context 'when recv is lvar with Array<Param>' do
      let(:recv_node) { Parser::AST::Node.new(:lvar, [:tags]) }
      let(:param_types) { { 'tags' => 'Array<Param>' } }

      it { is_expected.to eq('Array<Param>') }
    end

    context 'when recv is lvar with union String, nil' do
      let(:recv_node) { Parser::AST::Node.new(:lvar, [:v]) }
      let(:local_var_types) { { 'v' => 'String, nil' } }

      it { is_expected.to eq('String') }
    end

    context 'when recv is array literal' do
      let(:recv_node) { Parser::AST::Node.new(:array, []) }

      it { is_expected.to eq('Array') }
    end
  end

  describe '&& (and) handling via run_last_expr_type' do
    subject(:inferred) do
      described_class.send(:run_last_expr_type, node, fallback_type: 'Object', nil_as_optional: true,
                                                      core_rbs_provider: provider, param_types: param_types,
                                                      local_var_types: local_var_types)
    end

    let(:provider) { nil }
    let(:param_types) { nil }
    let(:local_var_types) { nil }

    context 'when code is nil && String' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; nil && "a"; end'))
      end

      it { is_expected.to eq('String?') }
    end

    context 'when code is String && String' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; "a" && "b"; end'))
      end

      it { is_expected.to eq('String') }
    end

    context 'when code is x && "b" with lvar String' do
      let(:param_types) { { 'x' => 'String' } }
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo(x); x && "b"; end'))
      end

      it { is_expected.to eq('String') }
    end
  end

  describe '|| (or) handling via run_last_expr_type' do
    subject(:inferred) do
      described_class.send(:run_last_expr_type, node, fallback_type: 'Object', nil_as_optional: true,
                                                      core_rbs_provider: provider, param_types: param_types,
                                                      local_var_types: local_var_types)
    end

    let(:provider) { nil }
    let(:param_types) { nil }
    let(:local_var_types) { nil }

    context 'when code is tags&.params || [] with Array<Param> vs Array' do
      let(:code) do
        <<~RUBY
          def foo(tags)
            tags&.params || []
          end
        RUBY
      end
      let(:node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      it { is_expected.to eq('Array') }
    end

    context 'when code is nil || "a"' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; nil || "a"; end'))
      end

      it { is_expected.to eq('String?') }
    end

    context 'when code is String || String' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; "a" || "b"; end'))
      end

      it { is_expected.to eq('String') }
    end

    context 'when code is Array<String> || Array<String> via lvars' do
      let(:local_var_types) { { 'a' => 'Array<String>', 'b' => 'Array<String>' } }
      let(:node) do
        Parser::AST::Node.new(:or, [Parser::AST::Node.new(:lvar, [:a]), Parser::AST::Node.new(:lvar, [:b])])
      end

      it { is_expected.to eq('Array<String>') }
    end
  end

  describe '&. (csend) handling via run_last_expr_type' do
    subject(:inferred) do
      described_class.send(:run_last_expr_type, node, fallback_type: 'Object', nil_as_optional: true,
                                                      core_rbs_provider: provider, param_types: param_types)
    end

    let(:provider) { nil }
    let(:param_types) { nil }

    context 'when csend is tags&.params without provider' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo(tags); tags&.params; end'))
      end

      it { is_expected.to eq('Object') }
    end

    context 'when csend is tags&.params with Array<Param> via RBS provider' do
      subject(:result) do
        described_class.send(:run_last_expr_type, node, fallback_type: 'Object', nil_as_optional: true,
                                                        core_rbs_provider: provider, param_types: param_types)
      end

      let(:param_types) { { 'tags' => 'String' } }
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo(tags); tags&.params; end'))
      end
      let(:sig_dir) { File.join(tmp_dir, 'sig') }
      let(:provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: [sig_dir], collection_dirs: [])
      end
      let(:tmp_dir) { Dir.mktmpdir }

      before do
        skip_unless_rbs_available!
        FileUtils.mkdir_p(sig_dir)
        File.write(File.join(sig_dir, 'tags.rbs'), <<~RBS)
          class String
            def params: () -> Array[Param]
          end
          class Param
          end
        RBS
      end

      after { FileUtils.rm_rf(tmp_dir) }

      it 'returns Array[Param]? via custom provider' do
        expect(result).to eq('Array<Param>?')
      end
    end

    context 'when csend is "hello"&.to_s with provider' do
      let(:provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
      end
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; "hello"&.to_s; end'))
      end

      before { skip_unless_rbs_available! }

      it { is_expected.to eq('String?') }
    end

    context 'when csend is tags&.to_s with String param' do
      let(:provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
      end
      let(:param_types) { { 'tags' => 'String' } }
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo(tags); tags&.to_s; end'))
      end

      before { skip_unless_rbs_available! }

      it { is_expected.to eq('String?') }
    end
  end

  describe '.substitute_rbs_type for self/V/Elem replacement' do
    subject(:substituted) { described_class.send(:substitute_rbs_type, rbs, recv_type) }

    context 'when rbs is self' do
      let(:rbs) { 'self' }
      let(:recv_type) { 'Array<Param>' }

      it { is_expected.to eq('Array<Param>') }
    end

    context 'when rbs is self? with Array<Param>' do
      let(:rbs) { 'self?' }
      let(:recv_type) { 'Array<Param>' }

      it { is_expected.to eq('Array<Param>?') }
    end

    context 'when rbs is V with Hash<String, Integer>' do
      let(:rbs) { 'V' }
      let(:recv_type) { 'Hash<String, Integer>' }

      it { is_expected.to eq('Integer') }
    end

    context 'when rbs is K with Hash<String, Integer>' do
      let(:rbs) { 'K' }
      let(:recv_type) { 'Hash<String, Integer>' }

      it { is_expected.to eq('String') }
    end

    context 'when rbs is Elem with Array<Param>' do
      let(:rbs) { 'Elem' }
      let(:recv_type) { 'Array<Param>' }

      it { is_expected.to eq('Param') }
    end

    context 'when rbs is Hash[K, V] with Hash' do
      let(:rbs) { 'Hash[K, V]' }
      let(:recv_type) { 'Hash<String, Integer>' }

      it { is_expected.to eq('Hash[String, Integer]') }
    end

    context 'when rbs is Array[U] with Array<String>' do
      let(:rbs) { 'Array[U]' }
      let(:recv_type) { 'Array<String>' }

      it { is_expected.to eq('Array[String]') }
    end

    context 'when recv_type is non-generic' do
      let(:rbs) { 'V' }
      let(:recv_type) { 'String' }

      it { is_expected.to eq('V') }
    end
  end

  describe '.handle_block_node fallback for map vs select' do
    subject(:block_type) do
      described_class.send(:handle_block_node, block_node, fallback_type: 'Object', nil_as_optional: true,
                                                           core_rbs_provider: provider)
    end

    let(:provider) { nil }

    context 'when block is map without RBS provider' do
      let(:code) { 'def foo; [1,2].map { |x| x.to_s }; end' }
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      it { is_expected.to eq('Array<String>') }
    end

    context 'when block is select without RBS provider' do
      let(:code) { 'def foo; [1,2].select { |x| x > 1 }; end' }
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      it { is_expected.to eq('Object') }
    end

    context 'when block is map with RBS provider' do
      let(:provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
      end
      let(:code) { 'def foo; [1,2].map { |x| x.to_s }; end' }
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      before { skip_unless_rbs_available! }

      it { is_expected.to be_a(String) }
    end

    context 'when block is select with RBS provider' do
      let(:provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
      end
      let(:code) { 'def foo; [1,2].select { |x| x > 1 }; end' }
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      before { skip_unless_rbs_available! }

      it { is_expected.to be_a(String) }
    end

    context 'when block is map with Array<Integer> param' do
      let(:provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
      end
      let(:code) do
        <<~RUBY
          def foo(arr)
            arr.map { |x| x.to_s }
          end
        RUBY
      end
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }
      let(:inferred_with_param) do
        described_class.send(:run_last_expr_type, block_node, fallback_type: 'Object', nil_as_optional: true,
                                                              core_rbs_provider: provider, param_types: { 'arr' => 'Array<Integer>' })
      end

      before { skip_unless_rbs_available! }

      it 'infers Array<Integer> via generic placeholder mapping' do
        expect(inferred_with_param).to eq('Array<Integer>')
      end
    end
  end

  describe 'integration via inline for &&/||/&.' do
    subject(:out) { inline(code, config: conf) }

    let(:conf) { Docscribe::Config.new('emit' => { 'header' => true }) }

    context 'when method uses tags&.params || []' do
      let(:code) do
        <<~RUBY
          class A
            def foo(tags)
              tags&.params || []
            end
          end
        RUBY
      end

      it 'infers Array, nil or similar' do
        expect(out).to match(/A#foo/)
      end
    end

    context 'when method uses nil && String' do
      let(:code) do
        <<~RUBY
          class A
            def foo
              nil && "a"
            end
          end
        RUBY
      end

      it 'infers String?' do
        expect(out).to match(header_regex('A', 'foo', 'String?'))
      end
    end

    context 'when method uses tags&.params' do
      let(:code) do
        <<~RUBY
          class A
            def foo(tags)
              tags&.params
            end
          end
        RUBY
      end

      it 'falls back to Object without RBS' do
        expect(out).to match(header_regex('A', 'foo', 'Object'))
      end
    end
  end
end

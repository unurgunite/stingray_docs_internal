# frozen_string_literal: true

# rubocop:disable RSpec/MultipleDescribes

require 'docscribe/validator/generic_compatibility'

RSpec.describe Docscribe::Validator::GenericCompatibility do
  subject(:mod) { described_class }

  describe '.compatible? dynamic checks (no hardcodes)' do
    context 'when generic base matches' do
      it 'treats Hash vs Hash<Symbol, String> as compatible' do
        expect(mod.compatible?('Hash', 'Hash<Symbol, String>')).to be true
      end

      it 'treats Array vs Array<String> as compatible' do
        expect(mod.compatible?('Array', 'Array<String>')).to be true
      end

      it 'detects mismatch when bases differ' do
        expect(mod.compatible?('Hash', 'Array<String>')).to be false
      end
    end

    context 'when short names equal (FQN vs short)' do
      it 'treats Parser::Source::Range vs Range as compatible' do
        expect(mod.compatible?('Parser::Source::Range', 'Range')).to be true
      end

      it 'treats Docscribe::Config vs Config as compatible' do
        expect(mod.compatible?('Docscribe::Config', 'Config')).to be true
      end

      it 'treats Result FQN vs Result as compatible' do
        expect(mod.compatible?('Docscribe::Validator::TypeMismatchValidator::Result', 'Result')).to be true
      end

      it 'detects mismatch when short differs' do
        expect(mod.compatible?('Docscribe::Config', 'String')).to be false
      end
    end

    context 'when alias hash with lowercase vs Hash' do
      it 'treats json_document vs Hash as compatible' do
        expect(mod.compatible?('Docscribe::CLI::Formatters::Json::json_document', 'Hash')).to be true
      end

      it 'treats custom alias my_alias vs Hash as compatible dynamically' do
        expect(mod.compatible?('Foo::Bar::my_custom_alias', 'Hash')).to be true
      end

      it 'does not treat Config (capital) vs Hash as compatible' do
        expect(mod.compatible?('Docscribe::Config', 'Hash')).to be false
      end
    end

    context 'when tuple vs Array' do
      it 'treats (String, Integer) vs Array as compatible' do
        expect(mod.compatible?('(String, Integer)', 'Array')).to be true
      end
    end

    context 'when optional vs nil' do
      it 'treats String? vs nil as compatible' do
        expect(mod.compatible?('String?', 'nil')).to be true
      end

      it 'treats String, nil vs nil as compatible' do
        expect(mod.compatible?('String, nil', 'nil')).to be true
      end

      it 'treats String vs nil as not compatible' do
        expect(mod.compatible?('String', 'nil')).to be false
      end
    end

    context 'when union containment' do
      it 'treats String vs String, Integer as compatible' do
        expect(mod.compatible?('String', 'String, Integer')).to be true
      end
    end

    context 'when optional suffix' do
      it 'treats String vs String? as compatible' do
        expect(mod.compatible?('String', 'String?')).to be true
      end
    end

    context 'when generic inner alias' do
      it 'treats Array<change> vs Array<String> as compatible for alias inner' do
        expect(mod.compatible?('Array<Docscribe::CLI::Formatters::change>', 'Array<String>')).to be true
      end

      it 'treats Array<Integer> vs Array<String> as not compatible' do
        expect(mod.compatible?('Array<Integer>', 'Array<String>')).to be false
      end
    end

    context 'when fallback union' do
      it 'treats Object as compatible with Object fallback' do
        expect(mod.compatible?('String', 'Object', fallback_type: 'Object')).to be true
      end
    end

    it 'uses map dispatch for generic checks' do
      expect(described_class::CHECKS).to be_a(Hash)
    end

    it 'includes expected check keys without hardcoding alias names' do
      expect(described_class::CHECKS.keys).to include(:generic_base, :short_name, :alias_hash, :tuple_array, :optional_nil)
    end

    it 'handles arbitrary user alias with lowercase as compatible' do
      expect(mod.compatible?('My::Custom::my_alias', 'Hash')).to be true
    end

    it 'does not treat capital alias as Hash compatible' do
      expect(mod.compatible?('My::Custom::AnotherAlias', 'Hash')).to be false
    end
  end

  describe 'helper methods' do
    it 'normalizes untyped to Object' do
      expect(mod.normalize('Hash[Symbol, untyped]')).to eq('Hash<Symbol, Object>')
    end

    it 'extracts short name' do
      expect(mod.short_name('Docscribe::CLI::Formatters::change')).to eq('change')
    end

    it 'extracts base name' do
      expect(mod.base_name('Array<String>')).to eq('Array')
    end
  end

  describe 'void with method_name dynamic' do
    context 'when yard is void and method is initialize' do
      it 'treats Hash as compatible', :aggregate_failures do
        expect(mod.compatible?('void', 'Hash', method_name: :initialize)).to be true
        expect(mod.compatible?('void', 'Hash<Symbol, String>', method_name: :initialize)).to be true
        expect(mod.compatible?('void', 'Hash[Symbol, String]', method_name: 'initialize')).to be true
      end

      it 'treats self as compatible' do
        expect(mod.compatible?('void', 'self', method_name: :initialize)).to be true
      end

      it 'treats Boolean as compatible' do
        expect(mod.compatible?('void', 'Boolean', method_name: :initialize)).to be true
      end

      it 'does not treat String as compatible' do
        expect(mod.compatible?('void', 'String', method_name: :initialize)).to be false
      end

      it 'treats setup as initialize alias', :aggregate_failures do
        expect(mod.compatible?('void', 'Hash', method_name: :setup)).to be true
        expect(mod.compatible?('void', 'self', method_name: :setup)).to be true
        expect(mod.compatible?('void', 'Boolean', method_name: 'setup')).to be true
      end
    end

    context 'when yard is void and method is predicate valid?' do
      it 'treats Boolean as compatible' do
        expect(mod.compatible?('void', 'Boolean', method_name: :valid?)).to be true
        expect(mod.compatible?('void', 'Boolean', method_name: 'valid?')).to be true
      end

      it 'does not treat Hash as compatible' do
        expect(mod.compatible?('void', 'Hash', method_name: :valid?)).to be false
      end

      it 'does not treat String as compatible' do
        expect(mod.compatible?('void', 'String', method_name: :valid?)).to be false
      end

      it 'handles generic predicate empty? as Boolean', :aggregate_failures do
        expect(mod.compatible?('void', 'Boolean', method_name: :empty?)).to be true
        expect(mod.compatible?('void', 'Hash', method_name: :empty?)).to be false
      end
    end

    context 'when yard is void without method_name' do
      it 'is not compatible with Hash/self/Boolean without method_name', :aggregate_failures do
        expect(mod.compatible?('void', 'Hash')).to be false
        expect(mod.compatible?('void', 'self')).to be false
        expect(mod.compatible?('void', 'Boolean')).to be false
      end

      it 'is still compatible with fallback/nil/void', :aggregate_failures do
        expect(mod.compatible?('void', 'Object')).to be true
        expect(mod.compatible?('void', 'nil')).to be true
        expect(mod.compatible?('void', 'void')).to be true
      end
    end

    it 'delegates via TypeMismatchValidator with method_name', :aggregate_failures do
      validator = Docscribe::Validator::TypeMismatchValidator.new
      expect(validator.mismatched_return?('void', 'Hash', method_name: :initialize)).to be false
      expect(validator.mismatched_return?('void', 'Boolean', method_name: :valid?)).to be false
      expect(validator.mismatched_return?('void', 'Hash', method_name: :valid?)).to be true
      expect(validator.mismatched_return?('void', 'String', method_name: :initialize)).to be true
    end
  end
end

RSpec.describe Docscribe::Infer::Returns do
  describe 'receiver_rbs_type_name for literals and lvars' do
    subject(:recv_type) { described_class.send(:receiver_rbs_type_name, recv_node, provider, local_var_types, param_types) }

    let(:provider) { nil }
    let(:local_var_types) { nil }
    let(:param_types) { nil }

    context 'when recv is nil literal' do
      let(:recv_node) { Parser::AST::Node.new(:nil, []) }

      it { is_expected.to eq('NilClass') }
    end

    context 'when recv is string literal' do
      let(:recv_node) { Parser::AST::Node.new(:str, ['hi']) }

      it { is_expected.to eq('String') }
    end

    context 'when recv is int literal' do
      let(:recv_node) { Parser::AST::Node.new(:int, [42]) }

      it { is_expected.to eq('Integer') }
    end

    context 'when recv is lvar with known type' do
      let(:recv_node) { Parser::AST::Node.new(:lvar, [:tags]) }
      let(:param_types) { { 'tags' => 'Array<String>' } }

      it { is_expected.to eq('Array<String>') }
    end

    context 'when recv is lvar with union containing nil' do
      let(:recv_node) { Parser::AST::Node.new(:lvar, [:val]) }
      let(:local_var_types) { { 'val' => 'String, nil' } }

      it { is_expected.to eq('String') }
    end

    context 'when recv is unknown lvar' do
      let(:recv_node) { Parser::AST::Node.new(:lvar, [:unknown]) }

      it { is_expected.to be_nil }
    end

    context 'when recv is :and node (unsupported)' do
      let(:recv_node) do
        Parser::AST::Node.new(:and, [Parser::AST::Node.new(:nil, []), Parser::AST::Node.new(:str, ['a'])])
      end

      it { is_expected.to eq('NilClass') }
    end

    context 'when recv is :or node (unsupported)' do
      let(:recv_node) do
        Parser::AST::Node.new(:or, [Parser::AST::Node.new(:nil, []), Parser::AST::Node.new(:str, ['a'])])
      end

      it { is_expected.to eq('NilClass') }
    end

    context 'when recv is :csend node (unsupported)' do
      let(:recv_node) do
        Parser::AST::Node.new(:csend, [Parser::AST::Node.new(:send, [nil, :tags]), :params])
      end

      it { is_expected.to eq('Object') }
    end
  end

  describe '&&/|| handling via run_last_expr_type' do
    subject(:inferred) do
      described_class.send(:run_last_expr_type, node, fallback_type: 'Object', nil_as_optional: true,
                                                      core_rbs_provider: provider, local_var_types: local_var_types,
                                                      param_types: param_types)
    end

    let(:provider) { nil }
    let(:local_var_types) { nil }
    let(:param_types) { nil }

    context 'when handling && with nil && String' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; nil && "a"; end'))
      end

      it { is_expected.to eq('String?') }
    end

    context 'when handling && with String && String' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; "a" && "b"; end'))
      end

      it { is_expected.to eq('String') }
    end

    context 'when handling || with nil || String' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; nil || "a"; end'))
      end

      it { is_expected.to eq('String?') }
    end

    context 'when handling || with String || String' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo; "a" || "b"; end'))
      end

      it { is_expected.to eq('String') }
    end

    context 'when handling || with Array<String> via lvars' do
      let(:local_var_types) { { 'a' => 'Array<String>', 'b' => 'Array<String>' } }
      let(:node) do
        Parser::AST::Node.new(:or, [Parser::AST::Node.new(:lvar, [:a]), Parser::AST::Node.new(:lvar, [:b])])
      end

      it { is_expected.to eq('Array<String>') }
    end

    context 'when handling tags&.params || [] with Array<Param>' do
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

    context 'when handling tags&.params || [] with Array<Param> and param type Array<String>' do
      subject(:result) do
        described_class.send(:run_last_expr_type, node, fallback_type: 'Object', nil_as_optional: true,
                                                        core_rbs_provider: rbs_provider, param_types: param_types)
      end

      let(:code) do
        <<~RUBY
          def foo(tags)
            tags&.params || []
          end
        RUBY
      end
      let(:node) { described_class.extract_def_body(described_class.parse_method_source(code)) }
      let(:param_types) { { 'tags' => 'Array<String>' } }
      let(:rbs_provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
      end

      before { skip_unless_rbs_available! }

      it 'unifies csend fallback with Array' do
        expect(result).to be_a(String)
      end
    end
  end

  describe '&. (csend) handling' do
    subject(:inferred) do
      described_class.send(:run_last_expr_type, node, fallback_type: fallback, nil_as_optional: true,
                                                      core_rbs_provider: provider, param_types: param_types)
    end

    let(:fallback) { 'Object' }
    let(:provider) { nil }
    let(:param_types) { nil }

    context 'when csend without provider' do
      let(:node) do
        described_class.extract_def_body(described_class.parse_method_source('def foo(tags); tags&.params; end'))
      end

      it { is_expected.to eq('Object') }
    end

    context 'when csend is "hello"&.to_s with RBS provider' do
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

    context 'when csend with lvar String and provider' do
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

  describe '.substitute_rbs_type for self/V/Elem' do
    subject(:substituted) { described_class.send(:substitute_rbs_type, rbs, recv_type) }

    context 'when rbs is self' do
      let(:rbs) { 'self' }
      let(:recv_type) { 'Array<String>' }

      it { is_expected.to eq('Array<String>') }
    end

    context 'when rbs is self?' do
      let(:rbs) { 'self?' }
      let(:recv_type) { 'MyClass' }

      it { is_expected.to eq('MyClass?') }
    end

    context 'when rbs is V with Hash' do
      let(:rbs) { 'V' }
      let(:recv_type) { 'Hash<String, Integer>' }

      it { is_expected.to eq('Integer') }
    end

    context 'when rbs is K with Hash' do
      let(:rbs) { 'K' }
      let(:recv_type) { 'Hash<String, Integer>' }

      it { is_expected.to eq('String') }
    end

    context 'when rbs is Elem with Array' do
      let(:rbs) { 'Elem' }
      let(:recv_type) { 'Array<String>' }

      it { is_expected.to eq('String') }
    end

    context 'when rbs is Array[Elem] with Array' do
      let(:rbs) { 'Array[Elem]' }
      let(:recv_type) { 'Array<String>' }

      it { is_expected.to eq('Array[String]') }
    end

    context 'when rbs is Hash[K, V] with Hash' do
      let(:rbs) { 'Hash[K, V]' }
      let(:recv_type) { 'Hash<String, Integer>' }

      it { is_expected.to eq('Hash[String, Integer]') }
    end

    context 'when rbs contains U with Array' do
      let(:rbs) { 'Array<U>' }
      let(:recv_type) { 'Array<Integer>' }

      it { is_expected.to eq('Array<Integer>') }
    end

    context 'when recv_type has no generic' do
      let(:rbs) { 'V' }
      let(:recv_type) { 'String' }

      it { is_expected.to eq('V') }
    end
  end

  describe '.handle_block_node fallback' do
    subject(:block_type) do
      described_class.send(:handle_block_node, block_node, fallback_type: 'Object', nil_as_optional: true,
                                                           core_rbs_provider: provider)
    end

    let(:provider) { nil }

    context 'when block without provider (map)' do
      let(:code) { 'def foo; [1,2].map { |x| x.to_s }; end' }
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      it { is_expected.to eq('Array<String>') }
    end

    context 'when block without provider (select)' do
      let(:code) { 'def foo; [1,2].select { |x| x > 1 }; end' }
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      it { is_expected.to eq('Object') }
    end

    context 'when block with RBS provider for map' do
      let(:provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
      end
      let(:code) { 'def foo; [1,2].map { |x| x.to_s }; end' }
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      before { skip_unless_rbs_available! }

      it { is_expected.to be_a(String) }
    end

    context 'when block with RBS provider for select' do
      let(:provider) do
        require 'docscribe/types/rbs/provider'
        Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig'], collection_dirs: [])
      end
      let(:code) { 'def foo; [1,2].select { |x| x > 1 }; end' }
      let(:block_node) { described_class.extract_def_body(described_class.parse_method_source(code)) }

      before { skip_unless_rbs_available! }

      it { is_expected.to be_a(String) }
    end
  end

  describe '.extract_generic_inner and .split_generic_args' do
    it 'extracts inner from Array<String>' do
      expect(described_class.send(:extract_generic_inner, 'Array<String>')).to eq('String')
    end

    it 'extracts inner from Hash<String, Integer>' do
      expect(described_class.send(:extract_generic_inner, 'Hash<String, Integer>')).to eq('String, Integer')
    end

    it 'returns nil for non-generic' do
      expect(described_class.send(:extract_generic_inner, 'String')).to be_nil
    end

    it 'splits generic args with nesting' do
      expect(described_class.send(:split_generic_args, 'String, Array<Integer>')).to eq(['String', 'Array<Integer>'])
    end

    it 'splits tuple-aware generic args' do
      expect(described_class.send(:split_generic_args, 'Integer, (String, Integer)')).to eq(['Integer', '(String, Integer)'])
    end
  end
end
# rubocop:enable RSpec/MultipleDescribes

# frozen_string_literal: true

RSpec.describe Docscribe::InlineRewriter do
  describe '**kwargs param inference' do
    context 'when method defines **kwargs' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(**kwargs); 0; end
          end
        RUBY
      end

      it 'infers Hash for **kwargs' do
        expect(output).to include('@param [Hash] kwargs')
      end
    end

    context 'when method defines **options alias' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(**options); 0; end
          end
        RUBY
      end

      it 'infers Hash for **options' do
        expect(output).to include('@param [Hash] options')
      end
    end

    context 'when method defines **kwargs alongside positional and block params' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(a, **kwargs, &blk); 0; end
          end
        RUBY
      end

      it 'infers Hash for kwargs and Proc for block', :aggregate_failures do
        expect(output).to include('@param [Hash] kwargs')
        expect(output).to include('@param [Proc] blk')
      end
    end

    context 'when **kwargs uses current Hash representation' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(**kwargs); 0; end
          end
        RUBY
      end

      it 'does not use Hash[Symbol, untyped] for **kwargs' do
        expect(output).not_to include('Hash[Symbol, untyped]')
      end

      it 'does not use Hash<Symbol, untyped> for **kwargs' do
        expect(output).not_to include('Hash<Symbol, untyped>')
      end
    end

    context 'when validating Hash compatibility for kwargs' do
      let(:validator) { Docscribe::Validator::TypeMismatchValidator.new }

      it 'treats generic Hash as compatible with Hash[Symbol, untyped]' do
        expect(validator.mismatched_return?('Hash', 'Hash[Symbol, untyped]')).to be false
      end
    end
  end

  describe 'Boolean inference' do
    context 'when param defaults to true' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(flag: true); 0; end
          end
        RUBY
      end

      it 'infers Boolean for true default' do
        expect(output).to include('@param [Boolean] flag')
      end
    end

    context 'when param defaults to false' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(flag: false); 0; end
          end
        RUBY
      end

      it 'infers Boolean for false default' do
        expect(output).to include('@param [Boolean] flag')
      end
    end

    context 'when multiple kwargs mix Boolean and Hash' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(verbose: true, options: {}); 0; end
          end
        RUBY
      end

      it 'infers Boolean and Hash together', :aggregate_failures do
        expect(output).to include('@param [Boolean] verbose')
        expect(output).to include('@param [Hash] options')
      end
    end

    context 'when return value is Boolean literal with header emission' do
      subject(:output) { inline(code, config: config) }

      let(:code) do
        <<~RUBY
          class Demo
            def a; true; end
            def b; false; end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('emit' => { 'header' => true }) }

      it 'infers Boolean for return true/false literals' do
        expect(output).to include('@return [Boolean]')
      end
    end

    context 'when if branches return true and false' do
      subject(:output) { inline(code, config: config) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(flag)
              if flag
                true
              else
                false
              end
            end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('emit' => { 'header' => true }) }

      it 'handles Boolean in union inference via if' do
        expect(output).to include('Boolean')
      end
    end
  end

  describe 'Array/Hash/Proc splats' do
    context 'when method defines *args' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(*args); 0; end
          end
        RUBY
      end

      it 'infers Array for *args' do
        expect(output).to include('@param [Array] args')
      end
    end

    context 'when method defines *args, **kwargs and &block together' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(*args, **kwargs, &block); 0; end
          end
        RUBY
      end

      it 'infers Array, Hash and Proc together', :aggregate_failures do
        expect(output).to include('@param [Array] args')
        expect(output).to include('@param [Hash] kwargs')
        expect(output).to include('@param [Proc] block')
      end
    end

    context 'when required keywords mix options and generic kw' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(options:, kw:); 0; end
          end
        RUBY
      end

      it 'infers Object for required keyword without default except options', :aggregate_failures do
        expect(output).to include('@param [Hash] options')
        expect(output).to include('@param [Object] kw')
      end
    end
  end

  describe 'FALLBACK_TYPE handling' do
    context 'when inference is uncertain' do
      subject(:output) { inline(code) }

      let(:code) do
        <<~RUBY
          class Foo
            def bar
              unknown_method
            end
          end
        RUBY
      end

      it 'uses fallback Object' do
        expect(output).to include('@return [Object]')
      end
    end

    context 'when inferred type is fallback' do
      let(:validator) { Docscribe::Validator::TypeMismatchValidator.new(fallback_type: 'Object') }

      it 'does not report mismatch via validator', :aggregate_failures do
        expect(validator.mismatched_return?('String', 'Object')).to be false
        expect(validator.check_return('String', 'Object')).to be_nil
      end
    end

    context 'when normalizing FALLBACK_TYPE alias' do
      let(:validator) { Docscribe::Validator::TypeMismatchValidator.new }

      it 'handles FALLBACK_TYPE alias via normalize', :aggregate_failures do
        expect(validator.send(:normalize, 'FALLBACK_TYPE')).to eq('Object')
        expect(validator.mismatched_return?('String', 'FALLBACK_TYPE')).to be false
        expect(validator.mismatched_return?('FALLBACK_TYPE', 'Object')).to be false
      end
    end

    context 'when method rescues and calls unknown' do
      subject(:output) { inline(code, config: config) }

      let(:code) do
        <<~RUBY
          class A
            def foo
              raise
            rescue
              unknown_call
            end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('emit' => { 'header' => true }) }

      it 'returns fallback for bare rescue else with unknown' do
        expect(output).to include('@return')
      end
    end
  end

  describe 'tuple vs Array compatibility in inference' do
    let(:validator) { Docscribe::Validator::TypeMismatchValidator.new }

    it 'treats tuple vs Array as compatible in one direction' do
      expect(validator.generic_compatible?('(String, Integer)', 'Array')).to be true
    end

    it 'treats Array vs tuple as compatible in reverse direction' do
      expect(validator.generic_compatible?('Array', '(String, Integer)')).to be true
    end

    context 'when YARD documents Array but inference is tuple' do
      let(:code) do
        <<~RUBY
          class Foo
            # @return [Array]
            def bar
              [1, "a"]
            end
          end
        RUBY
      end

      let(:validator) { Docscribe::Validator::TypeMismatchValidator.new }

      it 'does not flag mismatch for tuple vs Array via validate_types' do
        expect(validator.mismatched_return?('Array', '(String, Integer)')).to be false
      end
    end
  end

  describe 'infer returns with literals' do
    context 'when methods return literal values' do
      subject(:output) { inline(code, config: config) }

      let(:code) do
        <<~RUBY
          class Demo
            def a; 42; end
            def b; "hi"; end
            def c; :sym; end
            def d; true; end
            def e; 3.14; end
            def f; nil; end
            def g; []; end
            def h; {}; end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('emit' => { 'header' => true }) }

      it 'infers Integer for integer literal' do
        expect(output).to include('@return [Integer]')
      end

      it 'infers String for string literal' do
        expect(output).to include('@return [String]')
      end

      it 'infers Symbol for symbol literal' do
        expect(output).to include('@return [Symbol]')
      end

      it 'infers Boolean for true literal' do
        expect(output).to include('@return [Boolean]')
      end

      it 'infers Float for float literal' do
        expect(output).to include('@return [Float]')
      end

      it 'infers nil for nil literal' do
        expect(output).to include('@return [nil]')
      end

      it 'infers Array for array literal' do
        expect(output).to include('@return [Array]')
      end

      it 'infers Hash for hash literal' do
        expect(output).to include('@return [Hash]')
      end
    end

    context 'when return types unify via if branches' do
      subject(:output) { inline(code, config: config) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo(x)
              if x
                1
              else
                "a"
              end
            end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new('emit' => { 'header' => true }) }

      it 'infers unified union type' do
        expect(output).to match(/@return \[(Integer, String|String, Integer)\]/)
      end
    end
  end

  describe 'core_rbs_provider integration' do
    context 'when RBS is available' do
      subject(:output) { inline(code, config: config) }

      let(:code) do
        <<~RUBY
          class Demo
            def foo
              "hello".to_i
            end
          end
        RUBY
      end
      let(:config) { Docscribe::Config.new }

      before { skip_unless_rbs_available! }

      it 'uses RBS to infer return for known core methods' do
        expect(output).to include('@return')
      end
    end
  end
end

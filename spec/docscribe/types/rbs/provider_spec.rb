# frozen_string_literal: true

# rubocop:disable RSpec/NestedGroups

require 'tmpdir'

RSpec.describe 'Docscribe::Types::RBS::Provider' do
  before do
    skip_unless_rbs_available!
    require 'docscribe/types/rbs/provider'
  end

  let(:provider) { Docscribe::Types::RBS::Provider.new(sig_dirs: []) }

  describe '#definition_for' do
    before { provider.signature_for(container: 'Integer', scope: :instance, name: :to_s) }

    it 'strips YARD-style generic params (Array<String> -> Array)' do
      result = provider.send(:definition_for, container: 'Array<String>', scope: :instance)
      expect(result).not_to be_nil
    end

    it 'strips RBS-style generic params (Array[String] -> Array)' do
      result = provider.send(:definition_for, container: 'Array[String]', scope: :instance)
      expect(result).not_to be_nil
    end

    it 'returns nil for unknown type names' do
      result = provider.send(:definition_for, container: 'NonExistentFooBar', scope: :instance)
      expect(result).to be_nil
    end

    it 'works for plain class names' do
      result = provider.send(:definition_for, container: 'Integer', scope: :instance)
      expect(result).not_to be_nil
    end

    it 'handles nested generic params (Array[Array[String]] -> Array)' do
      result = provider.send(:definition_for, container: 'Array[Array[String]]', scope: :instance)
      expect(result).not_to be_nil
    end

    it 'handles singleton scope' do
      result = provider.send(:definition_for, container: 'String', scope: :class)
      expect(result).not_to be_nil
    end

    it 'returns nil for unknown singleton scope' do
      result = provider.send(:definition_for, container: 'NonExistentFooBar', scope: :class)
      expect(result).to be_nil
    end
  end

  describe '#signature_for' do
    context 'with a custom RBS class' do
      let(:root) { Dir.mktmpdir }
      let(:sig_dir) { File.join(root, 'sig') }
      let(:provider) { Docscribe::Types::RBS::Provider.new(sig_dirs: [sig_dir]) }

      before do
        FileUtils.mkdir_p(sig_dir)
        File.write(File.join(sig_dir, 'demo.rbs'), <<~RBS)
          class Demo
            def foo: (Array[String] items, Hash[Symbol, Integer] options) -> Array[Integer]
          end
        RBS
      end

      after { FileUtils.rm_rf(root) }

      it 'resolves a signature for a known class', :aggregate_failures do
        sig = provider.signature_for(container: 'Demo', scope: :instance, name: :foo)
        expect(sig).not_to be_nil
        expect(sig.param_types['items']).to eq('Array<String>')
        expect(sig.param_types['options']).to eq('Hash<Symbol, Integer>')
      end

      it 'resolves signature with YARD-style generic container name' do
        sig = provider.signature_for(container: 'Demo<String>', scope: :instance, name: :foo)
        expect(sig).not_to be_nil
      end

      it 'returns nil for unknown methods on known class' do
        sig = provider.signature_for(container: 'Demo', scope: :instance, name: :bar)
        expect(sig).to be_nil
      end

      it 'returns nil for unknown container' do
        sig = provider.signature_for(container: 'NonExistent', scope: :instance, name: :foo)
        expect(sig).to be_nil
      end
    end

    context 'with core stdlib types' do
      let(:provider) { Docscribe::Types::RBS::Provider.new(sig_dirs: []) }

      it 'resolves Array#map' do
        sig = provider.signature_for(container: 'Array', scope: :instance, name: :map)
        expect(sig).not_to be_nil
      end

      it 'resolves Array#map with YARD-style generic container' do
        sig = provider.signature_for(container: 'Array<String>', scope: :instance, name: :map)
        expect(sig).not_to be_nil
      end

      it 'resolves Array#map with RBS-style generic container' do
        sig = provider.signature_for(container: 'Array[Integer]', scope: :instance, name: :map)
        expect(sig).not_to be_nil
      end
    end

    context 'with rest keywords **kwargs' do
      let(:root) { Dir.mktmpdir }
      let(:sig_dir) { File.join(root, 'sig') }
      let(:provider) { Docscribe::Types::RBS::Provider.new(sig_dirs: [sig_dir]) }

      before do
        FileUtils.mkdir_p(sig_dir)
        File.write(File.join(sig_dir, 'rest.rbs'), <<~RBS)
          class DemoRest
            def foo: (**String) -> void
            def bar: (**Integer kwargs) -> String
            def baz: (String x, **Symbol opts) -> Integer
            def qux: (*String args, **String kwargs) -> void
            def plain: (String x) -> void
          end
        RBS
      end

      after { FileUtils.rm_rf(root) }

      context 'with anonymous **String' do
        subject(:sig) { provider.signature_for(container: 'DemoRest', scope: :instance, name: :foo) }

        it 'has rest_keywords with type String', :aggregate_failures do
          expect(sig).not_to be_nil
          expect(sig.rest_keywords).not_to be_nil
          expect(sig.rest_keywords.type).to eq('String')
        end

        it 'has nil name for anonymous rest keywords' do
          expect(sig.rest_keywords.name).to be_nil
        end
      end

      context 'with named **Integer kwargs' do
        subject(:sig) { provider.signature_for(container: 'DemoRest', scope: :instance, name: :bar) }

        it 'has rest_keywords with type Integer', :aggregate_failures do
          expect(sig).not_to be_nil
          expect(sig.rest_keywords).not_to be_nil
          expect(sig.rest_keywords.type).to eq('Integer')
        end

        it 'has kwargs name' do
          expect(sig.rest_keywords.name).to eq('kwargs')
        end

        it 'has correct return type' do
          expect(sig.return_type).to eq('String')
        end
      end

      context 'with required param plus **Symbol opts' do
        subject(:sig) { provider.signature_for(container: 'DemoRest', scope: :instance, name: :baz) }

        it 'has rest_keywords Symbol with name opts', :aggregate_failures do
          expect(sig.rest_keywords).not_to be_nil
          expect(sig.rest_keywords.type).to eq('Symbol')
          expect(sig.rest_keywords.name).to eq('opts')
        end

        it 'still has param_types for x' do
          expect(sig.param_types['x']).to eq('String')
        end
      end

      context 'with both *args and **kwargs' do
        subject(:sig) { provider.signature_for(container: 'DemoRest', scope: :instance, name: :qux) }

        it 'has rest_positional and rest_keywords', :aggregate_failures do
          expect(sig.rest_positional).not_to be_nil
          expect(sig.rest_positional.element_type).to eq('String')
          expect(sig.rest_keywords).not_to be_nil
          expect(sig.rest_keywords.type).to eq('String')
          expect(sig.rest_keywords.name).to eq('kwargs')
        end
      end

      context 'without rest keywords' do
        subject(:sig) { provider.signature_for(container: 'DemoRest', scope: :instance, name: :plain) }

        it 'has nil rest_keywords' do
          expect(sig.rest_keywords).to be_nil
        end
      end

      context 'with untyped rest' do
        subject(:sig) { provider2.signature_for(container: 'DemoUntyped', scope: :instance, name: :foo) }

        let(:root2) { Dir.mktmpdir }
        let(:sig_dir2) { File.join(root2, 'sig2') }
        let(:provider2) { Docscribe::Types::RBS::Provider.new(sig_dirs: [sig_dir2]) }

        before do
          FileUtils.mkdir_p(sig_dir2)
          File.write(File.join(sig_dir2, 'untyped.rbs'), <<~RBS)
            class DemoUntyped
              def foo: (**untyped) -> void
            end
          RBS
        end

        after { FileUtils.rm_rf(root2) }

        it 'formats untyped as Object', :aggregate_failures do
          expect(sig.rest_keywords).not_to be_nil
          expect(sig.rest_keywords.type).to eq('Object')
          expect(sig.rest_keywords.name).to be_nil
        end
      end
    end

    describe '#build_rest_keywords directly' do
      let(:provider) { Docscribe::Types::RBS::Provider.new(sig_dirs: []) }

      context 'when func has no rest_keywords' do
        subject(:result) { provider.send(:build_rest_keywords, func) }

        let(:func) do
          RBS::Types::Function.new(
            required_positionals: [],
            optional_positionals: [],
            rest_positionals: nil,
            trailing_positionals: [],
            required_keywords: {},
            optional_keywords: {},
            rest_keywords: nil,
            return_type: RBS::Types::Bases::Void.new(location: nil)
          )
        end

        it { is_expected.to be_nil }
      end

      context 'when func has rest_keywords' do
        subject(:result) { provider.send(:build_rest_keywords, func) }

        let(:string_type) { RBS::Types::ClassInstance.new(name: RBS::TypeName.new(name: :String, namespace: RBS::Namespace.new(path: [], absolute: true)), args: [], location: nil) }
        let(:param) { RBS::Types::Function::Param.new(name: :kwargs, type: string_type, location: nil) }
        let(:func) do
          RBS::Types::Function.new(
            required_positionals: [],
            optional_positionals: [],
            rest_positionals: nil,
            trailing_positionals: [],
            required_keywords: {},
            optional_keywords: {},
            rest_keywords: param,
            return_type: RBS::Types::Bases::Void.new(location: nil)
          )
        end

        it 'returns RestKeywords with type String', :aggregate_failures do
          expect(result).not_to be_nil
          expect(result.type).to eq('String')
          expect(result.name).to eq('kwargs')
        end
      end
    end
  end
end
# rubocop:enable RSpec/NestedGroups

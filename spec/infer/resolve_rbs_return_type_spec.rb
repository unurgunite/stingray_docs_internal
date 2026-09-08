# frozen_string_literal: true

require 'parser/current'
require 'docscribe/infer'
require 'docscribe/types/rbs/provider'
require 'docscribe/types/provider_chain'
require 'docscribe/inline_rewriter'
require 'docscribe/config'
require 'docscribe/validator/type_mismatch_validator'

RSpec.describe Docscribe::Infer::Returns do
  describe '.returns_spec_from_node for resolve_rbs_return_type' do
    let(:code) do
      <<~RUBY
        module Docscribe
          module Infer
            module Returns
              def resolve_rbs_return_type(container_type, method_name, core_rbs_provider)
                return FALLBACK_TYPE unless core_rbs_provider

                sig = core_rbs_provider.signature_for(
                  container: container_type,
                  scope: :instance,
                  name: method_name
                )

                sig&.return_type || FALLBACK_TYPE
              end
            end
          end
        end
      RUBY
    end

    let(:ast) { Parser::CurrentRuby.parse(code) }

    context 'without RBS provider' do
      let(:fallback_node) { find_def(ast, :resolve_rbs_return_type) }
      let(:fallback_spec) do
        described_class.returns_spec_from_node(
          fallback_node,
          fallback_type: 'Object',
          nil_as_optional: true,
          core_rbs_provider: nil
        )
      end

      it 'infers fallback Object' do
        expect(fallback_spec[:normal]).to eq('Object')
      end

      it 'does not include FALLBACK_TYPE' do
        expect(fallback_spec[:normal]).not_to include('FALLBACK_TYPE')
      end
    end

    context 'with RBS provider' do
      let(:rbs_provider) { Docscribe::Types::RBS::Provider.new(sig_dirs: ['sig']) }
      let(:rbs_chain) { Docscribe::Types::ProviderChain.new(rbs_provider) }
      let(:rbs_node) { find_def(ast, :resolve_rbs_return_type) }
      let(:rbs_param_types) do
        {
          'container_type' => 'String',
          'method_name' => 'String',
          'core_rbs_provider' => 'Docscribe::Types::RBS::Provider'
        }
      end
      let(:rbs_spec) do
        described_class.returns_spec_from_node(
          rbs_node,
          fallback_type: 'Object',
          nil_as_optional: true,
          core_rbs_provider: rbs_provider,
          signature_provider: rbs_chain,
          container: 'Docscribe::Infer::Returns',
          param_types: rbs_param_types
        )
      end

      it 'infers String via RBS when provider available' do
        skip_unless_rbs_available!
        expect(rbs_spec[:normal]).to eq('String?')
      end
    end

    context 'when validating fallback union' do
      let(:validator) { Docscribe::Validator::TypeMismatchValidator.new(fallback_type: 'Object') }

      it 'does not flag String as mismatch for Object' do
        expect(validator.mismatched_return?('String', 'Object')).to be false
      end

      it 'does not flag String as mismatch for Object, FALLBACK_TYPE' do
        expect(validator.mismatched_return?('String', 'Object, FALLBACK_TYPE')).to be false
      end

      it 'does not flag String mismatch for String?' do
        expect(validator.mismatched_return?('String', 'String?')).to be false
      end

      it 'does not flag String mismatch for String, nil' do
        expect(validator.mismatched_return?('String', 'String, nil')).to be false
      end
    end

    context 'with validate_types' do
      let(:yard_code) do
        <<~RUBY
          module Docscribe
            module Infer
              module Returns
                # @return [String]
                def resolve_rbs_return_type(container_type, method_name, core_rbs_provider)
                  return FALLBACK_TYPE unless core_rbs_provider
                  sig = core_rbs_provider.signature_for(container: container_type, scope: :instance, name: method_name)
                  sig&.return_type || FALLBACK_TYPE
                end
              end
            end
          end
        RUBY
      end
      let(:yard_config) { Docscribe::Config.new('validate_types' => true) }
      let(:yard_out) do
        Docscribe::InlineRewriter.insert_comments(yard_code, strategy: :safe, config: yard_config)
      end
      let(:yard_report) do
        Docscribe::InlineRewriter.rewrite_with_report(yard_code, strategy: :safe, config: yard_config)
      end
      let(:yard_updated) { yard_report[:changes].select { |c| c[:type] == :updated_return } }

      it 'preserves YARD String' do
        expect(yard_out).to include('@return [String]')
      end

      it 'does not include Object, FALLBACK_TYPE' do
        expect(yard_out).not_to include('Object, FALLBACK_TYPE')
      end

      it 'has no updated returns' do
        expect(yard_updated).to be_empty
      end
    end
  end
end

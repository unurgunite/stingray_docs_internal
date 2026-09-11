# frozen_string_literal: true

RSpec.describe 'Docscribe::Types::Sorbet::BaseProvider' do
  before do
    skip_unless_sorbet_bridge_available!
    require 'docscribe/types/sorbet/base_provider'
  end

  let(:provider) { Docscribe::Types::Sorbet::BaseProvider.new }

  # `_arg1` is a vcall where RBS::Prototype::RBI expects a type; RBS prints
  # "Unexpected type_node" to STDERR for it and falls back to `Any`.
  let(:source) do
    <<~RBI
      class Widget
        sig { params(legacy: _arg1).returns(Integer) }
        def measure(legacy); end
      end
    RBI
  end

  let(:load_source) { provider.send(:load_from_string, source, label: 'widget.rbi') }

  let(:measure_signature) do
    provider.signature_for(container: 'Widget', scope: :instance, name: :measure)
  end

  it 'indexes signatures even when the source has constructs RBS cannot model' do
    load_source

    expect(measure_signature&.return_type).to eq('Integer')
  end

  it 'writes nothing to STDERR while parsing unsupported constructs' do
    expect(with_captured_stderr { load_source }).to eq('')
  end

  it 'passes RBS parser noise through when DOCSCRIBE_RBS_DEBUG=1' do
    out = with_rbs_debug { with_captured_stderr { load_source } }

    expect(out).to include('Unexpected type_node')
  end
end

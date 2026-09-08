# frozen_string_literal: true

require 'docscribe/server'
require 'fileutils'
require 'json'
require 'tmpdir'

RSpec.describe Docscribe::Server::Client do
  subject(:client) { described_class.new(socket_path) }

  let(:socket_path) { "#{Dir.mktmpdir}/test.sock" }

  after do
    FileUtils.rm_rf(File.dirname(socket_path))
  end

  describe '#check' do
    it 'returns nil when server is unreachable' do
      expect(client.check(file: 'test.rb')).to be_nil
    end
  end

  describe '#fix' do
    it 'returns nil when server is unreachable' do
      expect(client.fix(file: 'test.rb')).to be_nil
    end
  end

  describe '#shutdown' do
    it 'returns nil when server is unreachable' do
      expect(client.shutdown).to be_nil
    end
  end

  describe '#ping' do
    it 'returns nil when server is unreachable' do
      expect(client.ping).to be_nil
    end
  end

  describe '#update_types' do
    let(:parsed) { JSON.parse(raw) }
    let(:update_types_args) { {} }
    let(:raw) { with_unix_server { |s| described_class.new(s).update_types(**update_types_args) } }

    it 'returns nil when server is unreachable' do
      expect(client.update_types(dir: 'lib')).to be_nil
    end

    context 'when dir is not specified' do
      it 'defaults dir to .' do
        expect(parsed).to include('method' => 'update_types',
                                  'params' => hash_including('dir' => '.'))
      end
    end

    context 'with custom dir' do
      let(:update_types_args) { { dir: 'app' } }

      it 'passes custom dir' do
        expect(parsed['params']['dir']).to eq('app')
      end
    end

    context 'with cli_overrides' do
      let(:update_types_args) { { dir: '.', cli_overrides: { 'no_boilerplate' => true } } }

      it 'forwards cli_overrides' do
        expect(parsed['params']['cli_overrides']).to eq('no_boilerplate' => true)
      end
    end
  end

  describe 'wire format' do
    it 'sends request with single trailing newline', :aggregate_failures do
      raw_data = with_unix_server { |s| described_class.new(s).check(file: 'test.rb') }
      expect(raw_data.count("\n")).to eq(1)
      expect(raw_data).to end_with("\n")
    end
  end
end

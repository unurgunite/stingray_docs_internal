# frozen_string_literal: true

RSpec.describe Docscribe::Server::Protocol do
  describe '.build_request' do
    subject(:request) { described_class.build_request('check', file: 'test.rb') }

    it 'includes jsonrpc version' do
      expect(request[:jsonrpc]).to eq('2.0')
    end

    it 'includes an id' do
      aggregate_failures do
        expect(request[:id]).to be_a(String)
        expect(request[:id].length).to eq(16)
      end
    end

    it 'includes the method name' do
      expect(request[:method]).to eq('check')
    end

    it 'includes params' do
      expect(request[:params]).to eq(file: 'test.rb')
    end
  end

  describe '.parse_response' do
    it 'parses valid JSON' do
      result = described_class.parse_response('{"id":1,"result":{"status":"ok"}}')
      aggregate_failures do
        expect(result['id']).to eq(1)
        expect(result['result']['status']).to eq('ok')
      end
    end

    it 'returns nil for invalid JSON' do
      expect(described_class.parse_response('not json')).to be_nil
    end

    it 'returns nil for empty string' do
      expect(described_class.parse_response('')).to be_nil
    end
  end

  describe '.serialize' do
    it 'produces JSON with trailing newline' do
      result = described_class.serialize({ a: 1 })
      expect(result).to eq("{\"a\":1}\n")
    end
  end
end

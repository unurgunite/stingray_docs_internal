# frozen_string_literal: true

require 'json'
require 'securerandom'

module Docscribe
  module Server
    # JSON-line protocol helpers.
    module Protocol
      module_function

      # Build a JSON-RPC request hash.
      #
      # @note module_function: defines #build_request (visibility: private)
      # @param [String] method method name
      # @param [Hash<Symbol, T>] params request parameters
      # @return [Hash<Symbol, String, Hash<Symbol, T>>]
      def build_request(method, params = {})
        {
          jsonrpc: '2.0',
          id: SecureRandom.hex(8),
          method: method,
          params: params
        }
      end

      # Parse a single JSON-line response.
      #
      # @note module_function: defines #parse_response (visibility: private)
      # @param [String] line raw JSON line
      # @raise [JSON::ParserError]
      # @return [Hash<String, Object>?]
      # @return [nil] if JSON::ParserError
      def parse_response(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      # Serialize a hash to a JSON line.
      #
      # @note module_function: defines #serialize (visibility: private)
      # @param [Object] hash
      # @return [String]
      def serialize(hash)
        "#{JSON.generate(hash)}\n"
      end
    end
  end
end

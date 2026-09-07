# frozen_string_literal: true

require 'docscribe/infer/raises'
require 'parser/current'

RSpec.describe Docscribe::Infer::Raises do
  describe '.exception_names_from_rescue_list' do
    it 'returns [DEFAULT_ERROR] for nil' do
      expect(described_class.exception_names_from_rescue_list(nil)).to eq(['StandardError'])
    end

    it 'returns single name for const node' do
      node = Parser::CurrentRuby.parse('StandardError')
      expect(described_class.exception_names_from_rescue_list(node)).to eq(['StandardError'])
    end

    it 'returns multiple names for array node via const_full_name' do
      array_node = Parser::AST::Node.new(:array, [
                                           Parser::AST::Node.new(:const, [nil, :StandardError]),
                                           Parser::AST::Node.new(:const, [nil, :ArgumentError])
                                         ])
      expect(described_class.exception_names_from_rescue_list(array_node)).to eq(%w[StandardError ArgumentError])
    end

    it 'handles non-Node gracefully' do
      expect(described_class.exception_names_from_rescue_list('not a node')).to eq(['StandardError'])
    end

    it 'handles inferred union Array<String> vs Array, Array<DEFAULT_ERROR>, Array via GenericCompatibility' do
      # YARD Array<String> should be compatible with inferred union containing DEFAULT_ERROR
      yard = 'Array<String>'
      inferred = 'Array, Array<DEFAULT_ERROR>, Array'
      expect(Docscribe::Validator::GenericCompatibility.compatible?(yard, inferred)).to be true
    end
  end

  describe '.infer_raises_from_node case with else' do
    it 'handles :resbody and :send without raising NoMethodError on nil node' do
      code = 'def foo; raise StandardError; rescue ArgumentError; end'
      ast = Docscribe::Infer::Returns.parse_method_source(code)
      expect { described_class.infer_raises_from_node(ast) }.not_to raise_error
    end

    it 'does not raise on nil type node' do
      expect { described_class.infer_raises_from_node(nil) }.not_to raise_error
    end
  end
end

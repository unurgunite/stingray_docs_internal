# frozen_string_literal: true

require 'docscribe/validator/generic_compatibility'

RSpec.describe Docscribe::Validator::GenericCompatibility do
  describe '.compatible? dynamic object supertype' do
    it 'considers String, nil vs Object, nil compatible (receiver_or_and_type)' do
      expect(described_class.compatible?('String, nil', 'Object, nil')).to be true
      expect(described_class.compatible?('Object, nil', 'String, nil')).to be true
    end

    it 'considers String vs Object compatible' do
      expect(described_class.compatible?('String', 'Object')).to be true
      expect(described_class.compatible?('Object', 'String')).to be true
    end

    it 'considers Array<String> vs Object compatible' do
      expect(described_class.compatible?('Array<String>', 'Object')).to be true
    end

    it 'still distinguishes String vs Integer' do
      expect(described_class.compatible?('String', 'Integer')).to be false
    end

    it 'handles then Enumerator case via String vs Enumerator not via object' do
      # rbs_output_path String vs Enumerator<String, Object> should be handled via infer, not via object_compatible
      # This just ensures object_compatible does not over-match String vs Enumerator
      expect(described_class.compatible?('String', 'Enumerator<String, Object>')).to be false
    end
  end
end

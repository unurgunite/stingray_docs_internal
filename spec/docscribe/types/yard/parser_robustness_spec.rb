# frozen_string_literal: true

require 'docscribe/types/yard/parser'

RSpec.describe Docscribe::Types::Yard::Parser do
  describe 'peek nilable guard and robust parsing' do
    let(:parser_class) { described_class }

    it 'does not raise on empty string after strip' do
      expect { parser_class.new('').parse }.not_to raise_error
    end

    it 'does not raise on whitespace only' do
      expect { parser_class.new('   ').parse }.not_to raise_error
    end

    context 'with String parser at end' do
      let(:parser) { parser_class.new('String') }

      before { parser.parse }

      it 'peek returns nil at end of string' do
        expect(parser.send(:peek)).to be_nil
      end
    end

    context 'with String and spaces parser' do
      let(:parser) { parser_class.new('String   ') }

      it 'skip_space handles end of string without NoMethodError', :aggregate_failures do
        expect { parser.send(:skip_space) }.not_to raise_error
        parser.instance_variable_set(:@i, parser.instance_variable_get(:@s).length)
        expect { parser.send(:skip_space) }.not_to raise_error
        expect(parser.send(:peek)).to be_nil
      end
    end

    context 'with Foo parser' do
      let(:parser) { parser_class.new('Foo') }
      let(:name) { parser.send(:scan_name) }

      before { parser.instance_variable_set(:@i, 0) }

      it 'scan_name handles end of string', :aggregate_failures do
        expect(name).to eq('Foo')
        expect(parser.send(:peek)).to be_nil
      end
    end

    context 'with incomplete generic' do
      let(:node) { Docscribe::Types::Yard.parse('Array<') }

      it 'parses incomplete generic without hanging', :aggregate_failures do
        expect { Docscribe::Types::Yard.parse('Array<') }.not_to raise_error
        expect(node).to be_a(Docscribe::Types::Yard::Generic)
      end
    end

    it 'parses String & without second type without raising' do
      expect { Docscribe::Types::Yard.parse('String &') }.not_to raise_error
    end

    it 'parses trailing spaces and comments gracefully', :aggregate_failures do
      expect { Docscribe::Types::Yard.parse('String   ') }.not_to raise_error
      expect(Docscribe::Types::Yard.parse('String   ')).to be_a(Docscribe::Types::Yard::Named)
    end

    it 'handles peek == comparisons without nil errors', :aggregate_failures do
      expect(Docscribe::Types::Yard.parse('String, Integer')).to be_a(Docscribe::Types::Yard::Union)
      expect(Docscribe::Types::Yard.parse('String & Integer')).to be_a(Docscribe::Types::Yard::Intersection)
      expect(Docscribe::Types::Yard.parse('Array<String | Integer>')).to be_a(Docscribe::Types::Yard::Generic)
      expect(Docscribe::Types::Yard.parse('Array<String | Integer>').args.first).to be_a(Docscribe::Types::Yard::Union)
    end

    it 'parses generic with trailing comma edge' do
      expect { Docscribe::Types::Yard.parse('Array<String,>') }.not_to raise_error
    end

    context 'with String parser beyond length' do
      let(:parser) { parser_class.new('String') }

      before do
        parser.send(:skip_space)
        parser.instance_variable_set(:@i, 100)
      end

      it 'skips spaces correctly at EOF', :aggregate_failures do
        expect(parser.send(:peek)).to be_nil
        expect { parser.send(:skip_space) }.not_to raise_error
      end
    end

    it 'duck type with no methods still parses' do
      expect { Docscribe::Types::Yard.parse('#') }.not_to raise_error
    end
  end
end

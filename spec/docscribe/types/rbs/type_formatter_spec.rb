# frozen_string_literal: true

RSpec.describe 'Docscribe::Types::RBS::TypeFormatter' do
  before do
    skip_unless_rbs_available!
    require 'docscribe/types/rbs/type_formatter'
  end

  describe '.to_yard' do
    let(:integer_type) { RBS::Types::ClassInstance.new(name: type_name('::Integer'), args: [], location: nil) }
    let(:string_type) { RBS::Types::ClassInstance.new(name: type_name('::String'), args: [], location: nil) }
    let(:void_function) do
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
    let(:proc_type) do
      RBS::Types::Proc.new(type: void_function, block: nil, location: nil, self_type: nil)
    end

    it 'returns Object for nil' do
      expect(yard(nil)).to eq('Object')
    end

    describe 'base types' do
      it 'formats Any as Object' do
        expect(yard(RBS::Types::Bases::Any.new(location: nil))).to eq('Object')
      end

      it 'formats Bool as Boolean' do
        expect(yard(RBS::Types::Bases::Bool.new(location: nil))).to eq('Boolean')
      end

      it 'formats Void as void' do
        expect(yard(RBS::Types::Bases::Void.new(location: nil))).to eq('void')
      end

      it 'formats Nil as nil' do
        expect(yard(RBS::Types::Bases::Nil.new(location: nil))).to eq('nil')
      end

      it 'formats Top as Object' do
        expect(yard(RBS::Types::Bases::Top.new(location: nil))).to eq('Object')
      end

      it 'formats Bottom as Object' do
        expect(yard(RBS::Types::Bases::Bottom.new(location: nil))).to eq('Object')
      end

      it 'formats Self as self' do
        expect(yard(RBS::Types::Bases::Self.new(location: nil))).to eq('self')
      end

      it 'formats Instance as Object' do
        expect(yard(RBS::Types::Bases::Instance.new(location: nil))).to eq('Object')
      end

      it 'formats Class as Class' do
        expect(yard(RBS::Types::Bases::Class.new(location: nil))).to eq('Class')
      end
    end

    describe 'compound types' do
      it 'formats Optional' do
        type = RBS::Types::Optional.new(type: string_type, location: nil)
        expect(yard(type)).to eq('String?')
      end

      it 'formats Union' do
        type = RBS::Types::Union.new(types: [string_type, integer_type], location: nil)
        expect(yard(type)).to eq('String, Integer')
      end

      it 'formats Tuple' do
        type = RBS::Types::Tuple.new(types: [string_type, integer_type], location: nil)
        expect(yard(type)).to eq('(String, Integer)')
      end

      it 'formats Record' do
        type = RBS::Types::Record.new(
          fields: { name: string_type, age: integer_type },
          location: nil
        )
        expect(yard(type)).to eq('Hash<Symbol, String, Integer>')
      end

      it 'formats Intersection' do
        type = RBS::Types::Intersection.new(types: [string_type, integer_type], location: nil)
        expect(yard(type)).to eq('String & Integer')
      end

      it 'formats Variable' do
        type = RBS::Types::Variable.new(name: :Elem, location: nil)
        expect(yard(type)).to eq('Elem')
      end

      it 'formats Proc' do
        expect(yard(proc_type)).to eq('Proc')
      end

      it 'formats Literal' do
        type = RBS::Types::Literal.new(literal: 42, location: nil)
        expect(yard(type)).to eq('Integer')
      end
    end

    describe 'collapse_object_generics option' do
      let(:object_type) { RBS::Types::Bases::Any.new(location: nil) }
      let(:string_type) { RBS::Types::ClassInstance.new(name: type_name('::String'), args: [], location: nil) }
      let(:integer_type) { RBS::Types::ClassInstance.new(name: type_name('::Integer'), args: [], location: nil) }

      it 'keeps Array<Object> when collapse_object_generics is false (default)' do
        type = RBS::Types::ClassInstance.new(name: type_name('::Array'), args: [object_type], location: nil)
        expect(yard_cog(type)).to eq('Array<Object>')
      end

      it 'collapses Array<Object> to Array when collapse_object_generics is true' do
        type = RBS::Types::ClassInstance.new(name: type_name('::Array'), args: [object_type], location: nil)
        expect(yard_cog(type, collapse_object_generics: true)).to eq('Array')
      end

      it 'keeps Array<String> when collapse_object_generics is true' do
        type = RBS::Types::ClassInstance.new(name: type_name('::Array'), args: [string_type], location: nil)
        expect(yard_cog(type, collapse_object_generics: true)).to eq('Array<String>')
      end

      it 'keeps Array<Integer> when collapse_object_generics is true' do
        type = RBS::Types::ClassInstance.new(name: type_name('::Array'), args: [integer_type], location: nil)
        expect(yard_cog(type, collapse_object_generics: true)).to eq('Array<Integer>')
      end

      it 'collapses Hash<Object, Object> to Hash when collapse_object_generics is true' do
        type = RBS::Types::ClassInstance.new(name: type_name('::Hash'), args: [object_type, object_type], location: nil)
        expect(yard_cog(type, collapse_object_generics: true)).to eq('Hash')
      end

      it 'keeps Hash<String, Integer> when collapse_object_generics is true' do
        type = RBS::Types::ClassInstance.new(name: type_name('::Hash'), args: [string_type, integer_type],
                                             location: nil)
        expect(yard_cog(type, collapse_object_generics: true)).to eq('Hash<String, Integer>')
      end

      it 'collapse_generics overrides collapse_object_generics' do
        type = RBS::Types::ClassInstance.new(name: type_name('::Array'), args: [string_type], location: nil)
        result = Docscribe::Types::RBS::TypeFormatter.to_yard(type, collapse_generics: true,
                                                                    collapse_object_generics: false)
        expect(result).to eq('Array')
      end
    end
  end
end

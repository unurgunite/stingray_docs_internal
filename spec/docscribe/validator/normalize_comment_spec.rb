# frozen_string_literal: true

require 'docscribe/validator/generic_compatibility'
require 'docscribe/validator/type_mismatch_validator'
require 'docscribe/inline_rewriter/doc_builder'

RSpec.describe Docscribe::Validator::GenericCompatibility do
  let(:generic_mod) { described_class }
  let(:validator) { Docscribe::Validator::TypeMismatchValidator.new }
  let(:builder) { Docscribe::InlineRewriter::DocBuilder }

  shared_examples 'strips trailing comment' do |method_name|
    it 'strips spaced comment' do
      expect(send(method_name, 'Hash<Object,Object> # foobar')).to eq('Hash<Object,Object>')
    end

    it 'strips tight comment without space' do
      expect(send(method_name, 'Hash<Object,Object>#foobar')).to eq('Hash<Object,Object>')
    end

    it 'strips spaced comment with multiple words' do
      expect(send(method_name, 'Hash<Object,Object> # comment with spaces')).to eq('Hash<Object,Object>')
    end

    it 'strips comment after bracket syntax' do
      expect(send(method_name, 'Hash[Symbol, String] # comment')).to eq('Hash<Symbol, String>')
    end

    it 'does not strip duck type starting with #' do
      expect(send(method_name, '#foo')).to eq('#foo')
    end

    it 'does not strip duck type with leading spaces' do
      expect(send(method_name, '  #foo')).to eq('#foo')
    end

    it 'handles empty after stripping comment only' do
      expect(send(method_name, '# comment only')).to eq('# comment only')
    end

    it 'handles type with trailing comment and newline' do
      expect(send(method_name, "Hash<Object,Object> #foobar\n")).to eq('Hash<Object,Object>')
    end

    it 'handles String with trailing comment' do
      expect(send(method_name, 'String # comment')).to eq('String')
    end

    it 'handles Array nested generic with tight comment' do
      expect(send(method_name, 'Array<Hash<String,Integer>>#foobar')).to eq('Array<Hash<String,Integer>>')
    end

    it 'handles Object fallback with comment' do
      expect(send(method_name, 'Object # fallback comment')).to eq('Object')
    end

    it 'handles optional nil with comment' do
      expect(send(method_name, 'String? # optional')).to eq('String?')
    end

    it 'handles Hash with inner comment after generic close' do
      expect(send(method_name, 'Hash<String, Integer> # trailing')).to eq('Hash<String, Integer>')
    end
  end

  describe 'GenericCompatibility.normalize' do
    it_behaves_like 'strips trailing comment', :generic_normalize
  end

  describe 'TypeMismatchValidator#normalize' do
    it_behaves_like 'strips trailing comment', :validator_normalize
  end

  describe 'DocBuilder.normalize_type' do
    it_behaves_like 'strips trailing comment', :builder_normalize
  end

  describe 'compatibility still detects mismatch after stripping' do
    it 'Hash<String,Integer> vs Hash<Object,Object> is mismatch' do
      expect(generic_mod.compatible?('Hash<String,Integer>', 'Hash<Object,Object>')).to be false
      expect(validator.mismatched_return?('Hash<String,Integer>', 'Hash<Object,Object>')).to be true
    end

    it 'Hash<String,Integer> vs Hash<Object,Object> # comment spaced still mismatch' do
      expect(generic_mod.compatible?('Hash<String,Integer>', 'Hash<Object,Object> # comment')).to be false
      expect(validator.mismatched_return?('Hash<String,Integer>', 'Hash<Object,Object> # comment')).to be true
    end

    it 'Hash<String,Integer> vs Hash<Object,Object>#foobar tight still mismatch' do
      expect(generic_mod.compatible?('Hash<String,Integer>', 'Hash<Object,Object>#foobar')).to be false
      expect(validator.mismatched_return?('Hash<String,Integer>', 'Hash<Object,Object>#foobar')).to be true
    end

    it 'String vs String #comment is compatible after stripping', :aggregate_failures do
      expect(generic_mod.compatible?('String', 'String # comment')).to be true
      expect(validator.mismatched_return?('String', 'String # comment')).to be false
      expect(builder.send(:normalized_equal?, 'String', 'String # comment')).to be true
    end

    it 'String vs String#tight is compatible' do
      expect(validator.mismatched_return?('String', 'String#tight')).to be false
    end

    it 'Array<String> vs Array<String> # comment is compatible' do
      expect(validator.mismatched_return?('Array<String>', 'Array<String> # hello')).to be false
    end

    it 'Array<String> vs Array<Integer> with comment still mismatch' do
      expect(generic_mod.compatible?('Array<String>', 'Array<Integer> # x')).to be false
      expect(validator.mismatched_return?('Array<String>', 'Array<Integer> # x')).to be true
    end

    it 'Hash<String,Array<Integer>> nested with comment stripped still mismatch against Object generic' do
      expect(generic_mod.compatible?('Hash<String,Array<Integer>>', 'Hash<Object,Object> # c')).to be false
    end

    it 'Object vs String with comment on Object still compatible via object_compatible?' do
      expect(generic_mod.compatible?('String', 'Object # comment')).to be true
    end

    it 'duck type #foo not stripped remains mismatch vs String' do
      expect(generic_mod.send(:normalize, '#foo')).to eq('#foo')
      expect(generic_mod.compatible?('#foo', 'String')).to be false
    end

    it 'yard_in_expected_union with comment still works' do
      expect(validator.yard_in_expected_union?('String', 'String # comment, Integer')).to be true
    end

    it 'fallback_union with comments still recognized' do
      expect(validator.fallback_union?('Object # comment')).to be true
      expect(generic_mod.send(:fallback_union?, 'Object # comment', 'Object')).to be true
    end
  end

  describe 'multiline and edge cases' do
    it 'handles type with hash inside generic not stripped incorrectly' do
      expect(generic_normalize('Hash<String, Integer>#c')).to eq('Hash<String, Integer>')
    end

    it 'handles blank string with comment' do
      expect(generic_normalize('   # only comment')).to eq('# only comment')
    end

    it 'handles nil input gracefully', :aggregate_failures do
      expect(generic_normalize(nil)).to eq('')
      expect(validator_normalize(nil)).to eq('')
      expect(builder_normalize(nil)).to eq('')
    end

    it 'handles String? optional with tight comment' do
      expect(generic_normalize('String?#foo')).to eq('String?')
      expect(generic_mod.compatible?('String', 'String?#foo')).to be true
    end
  end
end

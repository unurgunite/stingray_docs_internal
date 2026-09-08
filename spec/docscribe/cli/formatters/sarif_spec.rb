# frozen_string_literal: true

require 'docscribe/cli/formatters'

RSpec.describe Docscribe::CLI::Formatters::Sarif do
  subject(:formatter) { described_class.new }

  let(:options) { { verbose: false, quiet: false, explain: false, mode: :check, format: :sarif } }

  let(:state) do
    {
      changed: false, had_errors: false, checked_ok: 0, checked_fail: 0,
      corrected: 0, corrected_paths: [], corrected_changes: {},
      fail_paths: [], fail_changes: {},
      error_paths: [], error_messages: {},
      type_mismatch_paths: [], type_mismatch_changes: {}
    }
  end

  describe '#format_check_summary' do
    it 'outputs valid JSON' do
      expect { parse_output }.not_to raise_error
    end

    it 'has top-level $schema' do
      expect(parse_output['$schema']).to eq('https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json')
    end

    it 'has version 2.1.0' do
      expect(parse_output['version']).to eq('2.1.0')
    end

    it 'has runs as an array' do
      expect(runs).to be_an(Array)
    end

    it 'has exactly one run' do
      expect(runs.size).to eq(1)
    end

    it 'has docscribe driver name' do
      expect(driver['name']).to eq('docscribe')
    end

    it 'has version' do
      expect(driver['version']).to eq(Docscribe::VERSION)
    end

    it 'has informationUri' do
      expect(driver['informationUri']).to eq('https://github.com/unurgunite/docscribe')
    end

    it 'is executionSuccessful when no errors' do
      expect(invocation['executionSuccessful']).to be(true)
    end

    it 'is not executionSuccessful with errors' do
      state.merge!(had_errors: true)
      expect(invocation['executionSuccessful']).to be(false)
    end

    context 'with empty state' do
      it 'has empty results array' do
        expect(results).to eq([])
      end
    end

    context 'with fail paths' do
      before do
        state.merge!(
          checked_fail: 1,
          fail_paths: ['foo.rb'],
          fail_changes: { 'foo.rb' => [{ type: :missing_return, line: 10, method: 'Foo#bar' }] }
        )
      end

      it 'produces one result' do
        expect(results.size).to eq(1)
      end

      it 'has note severity' do
        expect(results[0]['level']).to eq('note')
      end

      it 'has MissingReturn ruleId' do
        expect(results[0]['ruleId']).to eq('Docscribe/MissingReturn')
      end

      it 'has message text' do
        expect(results[0]['message']['text']).to eq('missing return for Foo#bar at line 10')
      end

      it 'has location uri' do
        loc = results[0]['locations'][0]
        expect(loc['physicalLocation']['artifactLocation']['uri']).to eq('foo.rb')
      end

      it 'has location startLine' do
        loc = results[0]['locations'][0]
        expect(loc['physicalLocation']['region']['startLine']).to eq(10)
      end
    end

    context 'with type mismatches' do
      before do
        state.merge!(
          checked_ok: 1,
          type_mismatch_paths: ['types.rb'],
          type_mismatch_changes: { 'types.rb' => [{ type: :updated_return, line: 5, method: 'Foo#bar' }] }
        )
      end

      it 'produces one result' do
        expect(results.size).to eq(1)
      end

      it 'has warning severity' do
        expect(results[0]['level']).to eq('warning')
      end

      it 'has UpdatedReturn ruleId' do
        expect(results[0]['ruleId']).to eq('Docscribe/UpdatedReturn')
      end
    end

    context 'with source field' do
      before do
        state.merge!(
          checked_fail: 1,
          fail_paths: ['test.rb'],
          fail_changes: { 'test.rb' => [{ type: :updated_param, line: 5, method: 'Foo#bar', source: 'rbs' }] }
        )
      end

      it 'includes source in properties' do
        expect(results[0]['properties']['source']).to eq('rbs')
      end
    end

    context 'with errors' do
      before do
        state.merge!(
          had_errors: true,
          error_paths: ['broken.rb'],
          error_messages: { 'broken.rb' => 'StandardError: boom' }
        )
      end

      it 'produces one result' do
        expect(results.size).to eq(1)
      end

      it 'has error severity' do
        expect(results[0]['level']).to eq('error')
      end

      it 'has ProcessingError ruleId' do
        expect(results[0]['ruleId']).to eq('Docscribe/ProcessingError')
      end

      it 'has error message text' do
        expect(results[0]['message']['text']).to eq('StandardError: boom')
      end
    end

    context 'with corrected paths' do
      before do
        state.merge!(
          corrected: 1,
          corrected_paths: ['foo.rb'],
          corrected_changes: { 'foo.rb' => [{ type: :insert_full_doc_block, line: 3, method: 'Foo#bar' }] }
        )
      end

      it 'produces one result' do
        expect(results.size).to eq(1)
      end

      it 'has note severity' do
        expect(results[0]['level']).to eq('note')
      end

      it 'has MissingDocBlock ruleId' do
        expect(results[0]['ruleId']).to eq('Docscribe/MissingDocBlock')
      end
    end

    context 'with mixed results' do
      before do
        state.merge!(
          checked_fail: 2,
          fail_paths: ['a.rb'],
          fail_changes: { 'a.rb' => [
            { type: :missing_param, line: 1, method: 'Foo#bar' },
            { type: :unsorted_tags, line: 2, method: 'Foo#bar' }
          ] }
        )
      end

      it 'produces multiple results' do
        expect(results.size).to eq(2)
      end

      it 'maps first change to MissingParam' do
        expect(results[0]['ruleId']).to eq('Docscribe/MissingParam')
      end

      it 'maps second change to UnsortedTags' do
        expect(results[1]['ruleId']).to eq('Docscribe/UnsortedTags')
      end
    end
  end

  describe '#format_write_summary' do
    let(:options) { { verbose: false, quiet: false, mode: :write, format: :sarif } }

    before do
      state.merge!(
        corrected: 1,
        corrected_paths: ['foo.rb'],
        corrected_changes: { 'foo.rb' => [{ type: :insert_full_doc_block, line: 3, method: 'Foo#bar' }] }
      )
    end

    it 'outputs valid JSON' do
      expect { parse_write_output }.not_to raise_error
    end

    it 'has $schema' do
      out = parse_write_output
      expect(out['$schema']).to eq('https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json')
    end

    it 'has version 2.1.0' do
      expect(parse_write_output['version']).to eq('2.1.0')
    end

    it 'has runs array' do
      expect(parse_write_output['runs']).to be_an(Array)
    end

    it 'includes one result' do
      out = parse_write_output
      expect(out['runs'][0]['results'].size).to eq(1)
    end

    it 'includes MissingDocBlock ruleId' do
      out = parse_write_output
      expect(out['runs'][0]['results'][0]['ruleId']).to eq('Docscribe/MissingDocBlock')
    end
  end
end

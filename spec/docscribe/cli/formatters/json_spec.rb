# frozen_string_literal: true

require 'json'
require 'docscribe/cli/formatters'

RSpec.describe Docscribe::CLI::Formatters::Json do
  subject(:formatter) { described_class.new }

  let(:options) { { verbose: false, quiet: false, explain: false, mode: :check } }

  let(:state) do
    {
      changed: false, had_errors: false, checked_ok: 0, checked_fail: 0,
      corrected: 0, corrected_paths: [], corrected_changes: {},
      fail_paths: [], fail_changes: {},
      error_paths: [], error_messages: {},
      type_mismatch_paths: [], type_mismatch_changes: {}
    }
  end

  let(:parse_output) do
    JSON.parse(capture_stdout { formatter.format_check_summary(state: state, options: options) })
  end

  describe '#format_check_summary' do
    it 'outputs valid JSON' do
      expect { parse_output }.not_to raise_error
    end

    it 'includes version in metadata' do
      expect(parse_output['metadata']['docscribe_version']).to eq(Docscribe::VERSION)
    end

    context 'with fail paths' do
      before do
        state.merge!(
          checked_ok: 5,
          checked_fail: 1,
          fail_paths: ['foo.rb'],
          fail_changes: { 'foo.rb' => [{ type: :missing_return, line: 10, method: 'Foo#bar' }] }
        )
      end

      it 'includes one file' do
        expect(parse_output['files'].size).to eq(1)
      end

      it 'sets file path' do
        expect(parse_output['files'][0]['path']).to eq('foo.rb')
      end

      it 'includes one offense' do
        expect(parse_output['files'][0]['offenses'].size).to eq(1)
      end

      it 'counts offenses in summary' do
        expect(parse_output['summary']['offense_count']).to eq(1)
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

      it 'includes fatal severity' do
        expect(parse_output['files'][0]['offenses'][0]['severity']).to eq('fatal')
      end

      it 'uses ProcessingError cop_name' do
        expect(parse_output['files'][0]['offenses'][0]['cop_name']).to eq('Docscribe/ProcessingError')
      end

      it 'counts errors in summary' do
        expect(parse_output['summary']['error_count']).to eq(1)
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

      it 'uses warning severity' do
        expect(parse_output['files'][0]['offenses'][0]['severity']).to eq('warning')
      end

      it 'uses UpdatedReturn cop_name' do
        expect(parse_output['files'][0]['offenses'][0]['cop_name']).to eq('Docscribe/UpdatedReturn')
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

      it 'includes source in offense' do
        expect(parse_output['files'][0]['offenses'][0]['source']).to eq('rbs')
      end
    end

    context 'with nothing to report' do
      it 'outputs empty files array' do
        expect(parse_output['files']).to eq([])
      end

      it 'has zero offense count' do
        expect(parse_output['summary']['offense_count']).to eq(0)
      end
    end
  end

  describe '#format_write_summary' do
    let(:options) { { verbose: false, quiet: false, mode: :write } }

    before do
      state.merge!(
        corrected: 1,
        corrected_paths: ['foo.rb'],
        corrected_changes: { 'foo.rb' => [{ type: :insert_full_doc_block, line: 3, method: 'Foo#bar' }] }
      )
    end

    it 'includes one file' do
      out = capture_stdout { formatter.format_write_summary(state: state, options: options) }
      expect(JSON.parse(out)['files'].size).to eq(1)
    end

    it 'counts inspected files' do
      out = capture_stdout { formatter.format_write_summary(state: state, options: options) }
      expect(JSON.parse(out)['summary']['inspected_file_count']).to eq(1)
    end
  end

  describe 'offense structure' do
    before do
      state.merge!(
        checked_fail: 1,
        fail_paths: ['test.rb'],
        fail_changes: { 'test.rb' => [{ type: :missing_param, line: 5, method: 'Foo#bar',
                                        message: 'missing @param [String] name' }] }
      )
    end

    let(:offense) { parse_output['files'][0]['offenses'][0] }

    it 'has convention severity' do
      expect(offense['severity']).to eq('convention')
    end

    it 'has Docscribe/MissingParam cop_name' do
      expect(offense['cop_name']).to eq('Docscribe/MissingParam')
    end

    it 'is not corrected' do
      expect(offense['corrected']).to be(false)
    end

    it 'is correctable' do
      expect(offense['correctable']).to be(true)
    end

    it 'has location with line info' do
      expect(offense['location']).to include('start_line', 'start_column', 'last_line', 'last_column')
    end
  end
end

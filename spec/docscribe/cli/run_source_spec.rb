# frozen_string_literal: true

require 'docscribe/cli/run'
require 'docscribe/cli/formatters'

RSpec.describe Docscribe::CLI::Run do
  describe '.symbolize_change handling source' do
    subject(:symbolized_changes) { raw_changes.map { |change| described_class.send(:symbolize_change, change) } }

    let(:raw_changes) do
      [
        { 'type' => 'updated_return', 'file' => 'a.rb', 'line' => 1, 'method' => 'A#foo', 'message' => 'msg', 'source' => 'rbs' },
        { 'type' => 'updated_param', 'file' => 'a.rb', 'line' => 2, 'method' => 'A#bar', 'message' => 'msg2', 'source' => 'infer', 'param' => 'x' },
        { 'type' => 'invalid_type', 'file' => 'a.rb', 'line' => 3, 'method' => 'A#baz', 'message' => 'msg3', 'source' => 'syntax' }
      ]
    end
    let(:symbolized_without_source) { described_class.send(:symbolize_change, raw_change_without_source) }
    let(:raw_change_without_source) do
      { 'type' => 'missing_return', 'file' => 'b.rb', 'line' => 1, 'method' => 'B#foo', 'message' => 'm' }
    end

    it 'preserves source rbs/infer/syntax through symbolize and formatters', :aggregate_failures do
      expect(symbolized_changes[0][:source]).to eq('rbs')
      expect(symbolized_changes[1][:source]).to eq('infer')
      expect(symbolized_changes[2][:source]).to eq('syntax')
      expect(symbolized_changes[1][:param]).to eq('x')
      expect(symbolized_without_source).not_to have_key(:source)
    end
  end

  describe 'formatters via run path' do
    let(:json_formatter) { Docscribe::CLI::Formatters::Json.new }
    let(:sarif_formatter) { Docscribe::CLI::Formatters::Sarif.new }

    let(:state) do
      {
        changed: false, had_errors: false, checked_ok: 0, checked_fail: 3,
        corrected: 0, corrected_paths: [], corrected_changes: {},
        fail_paths: ['a.rb'],
        fail_changes: { 'a.rb' => [
          { type: :updated_return, line: 1, method: 'A#foo', source: 'rbs' },
          { type: :updated_param, line: 2, method: 'A#bar', source: 'infer' },
          { type: :invalid_type, line: 3, method: 'A#baz', source: 'syntax' }
        ] },
        error_paths: [], error_messages: {},
        type_mismatch_paths: [], type_mismatch_changes: {}
      }
    end

    let(:base_options) { { verbose: false, quiet: false, explain: false, mode: :check } }
    let(:check_options) { base_options }
    let(:sarif_options) { base_options.merge(format: :sarif) }

    describe 'json formatter' do
      subject(:parsed_json) do
        JSON.parse(capture_stdout { json_formatter.format_check_summary(state: state, options: check_options) })
      end

      let(:json_sources) { parsed_json['files'][0]['offenses'].map { |offense| offense['source'] } }

      it 'includes source for all three kinds' do
        expect(json_sources).to eq(%w[rbs infer syntax])
      end
    end

    describe 'sarif formatter' do
      subject(:parsed_sarif) do
        JSON.parse(capture_stdout { sarif_formatter.format_check_summary(state: state, options: sarif_options) })
      end

      let(:sarif_sources) { parsed_sarif['runs'][0]['results'].map { |result| result['properties']['source'] } }

      it 'includes source in properties for all three' do
        expect(sarif_sources).to eq(%w[rbs infer syntax])
      end
    end
  end
end

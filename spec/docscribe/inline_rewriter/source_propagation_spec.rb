# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'json'
require 'docscribe/inline_rewriter'
require 'docscribe/config'
require 'docscribe/cli/formatters'
require 'docscribe/server'

RSpec.describe Docscribe::InlineRewriter do
  describe 'source field propagation (442)' do
    let(:config_validate) { Docscribe::Config.new('validate_types' => true) }
    let(:config_no_validate) { Docscribe::Config.new('validate_types' => false) }

    context 'when YARD return type is invalid syntax' do
      subject(:rewrite_result) do
        described_class.rewrite_with_report(code, strategy: :safe, config: config_validate, file: 'test.rb')
      end

      let(:code) do
        <<~RUBY
          class Foo
            # @return [Sym bol]
            def bar
              :x
            end
          end
        RUBY
      end
      let(:first_change) { rewrite_result[:changes].first }

      it 'reports one change for invalid YARD syntax' do
        expect(rewrite_result[:changes].size).to eq(1)
      end

      it 'reports invalid_type type for invalid syntax' do
        expect(first_change[:type]).to eq(:invalid_type)
      end

      it 'reports source syntax for invalid YARD' do
        expect(first_change[:source]).to eq('syntax')
      end

      it 'includes invalid token in message' do
        expect(first_change[:message]).to include('Sym bol')
      end
    end

    context 'when YARD return type mismatches inferred type without RBS' do
      subject(:rewrite_result) do
        described_class.rewrite_with_report(code, strategy: :safe, config: config_validate, file: 'test.rb')
      end

      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end
      let(:first_change) { rewrite_result[:changes].first }

      it 'reports one change for YARD mismatch' do
        expect(rewrite_result[:changes].size).to eq(1)
      end

      it 'reports source infer for YARD mismatch' do
        expect(first_change[:source]).to eq('infer')
      end

      it 'reports updated_return type for YARD mismatch' do
        expect(first_change[:type]).to eq(:updated_return)
      end
    end

    context 'when external RBS signature differs from YARD' do
      subject(:rbs_result) { rewrite_with_rbs(code, rbs_content) }

      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end
      let(:rbs_change) { rbs_result[:changes].first }
      let(:rbs_content) { "class Foo\n  def bar: () -> String\nend\n" }

      before { skip_unless_rbs_available! }

      it 'reports source rbs when external_sig differs' do
        expect(rbs_change[:source]).to eq('rbs')
      end

      it 'reports updated_return type when external_sig differs' do
        expect(rbs_change[:type]).to eq(:updated_return)
      end
    end

    context 'when YARD param type is invalid syntax' do
      subject(:rewrite_result) do
        described_class.rewrite_with_report(code, strategy: :safe, config: config_no_validate, file: 'test.rb')
      end

      let(:code) do
        <<~RUBY
          class Foo
            # @param [Sym bol] x
            # @return [Symbol]
            def bar(x = :sym)
              x
            end
          end
        RUBY
      end
      let(:param_change) { rewrite_result[:changes].find { |entry| entry[:type] == :invalid_type } }

      it 'reports invalid_type change for param invalid syntax' do
        expect(param_change).not_to be_nil
      end

      it 'reports source syntax for param invalid' do
        expect(param_change[:source]).to eq('syntax')
      end
    end

    context 'when YARD param type mismatches inferred default' do
      subject(:rewrite_result) do
        described_class.rewrite_with_report(code, strategy: :safe, config: config_validate, file: 'test.rb')
      end

      let(:code) do
        <<~RUBY
          class Foo
            # @param [String] x
            # @return [Object]
            def bar(x: 123)
              x
            end
          end
        RUBY
      end
      let(:param_change) { rewrite_result[:changes].find { |entry| entry[:type] == :updated_param } }

      it 'reports updated_param change for param mismatch' do
        expect(param_change).not_to be_nil
      end

      it 'reports source infer for param mismatch' do
        expect(param_change[:source]).to eq('infer')
      end

      it 'reports param name x for param mismatch' do
        expect(param_change[:param]).to eq('x')
      end
    end

    context 'when RBS provides param type differing from YARD' do
      subject(:rbs_param_change) { param_change_with_rbs(code, rbs_content) }

      let(:code) do
        <<~RUBY
          class Foo
            # @param [String] x
            # @return [Object]
            def bar(x)
              x
            end
          end
        RUBY
      end
      let(:rbs_content) { "class Foo\n  def bar: (Integer x) -> Object\nend\n" }

      before { skip_unless_rbs_available! }

      it 'reports param change present for rbs mismatch' do
        expect(rbs_param_change).not_to be_nil
      end

      it 'reports source rbs for param mismatch' do
        expect(rbs_param_change[:source]).to eq('rbs')
      end
    end

    context 'when no validation and no invalid syntax' do
      subject(:rewrite_result) do
        described_class.rewrite_with_report(code, strategy: :safe, config: config_no_validate, file: 'test.rb')
      end

      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end

      it 'does not report updated_return without validation' do
        expect(rewrite_result[:changes].any? { |entry| entry[:type] == :updated_return }).to be false
      end
    end

    context 'when comparing safe and aggressive strategies' do
      subject(:safe_result) do
        described_class.rewrite_with_report(code, strategy: :safe, config: config_validate, file: 'test.rb')
      end

      let(:code) do
        <<~RUBY
          class Foo
            # @return [Integer]
            def bar
              "hello"
            end
          end
        RUBY
      end
      let(:aggressive_result) do
        described_class.rewrite_with_report(code, strategy: :aggressive, config: config_validate, file: 'test.rb')
      end
      let(:safe_change) { safe_result[:changes].first }

      it 'preserves source infer in safe mode' do
        expect(safe_change[:source]).to eq('infer')
      end

      it 'preserves updated_return type in safe mode' do
        expect(safe_change[:type]).to eq(:updated_return)
      end

      it 'generates corrected output in aggressive mode' do
        expect(aggressive_result[:output]).to include('@return [String]')
      end
    end
  end

  describe 'formatters source propagation' do
    let(:formatter_json) { Docscribe::CLI::Formatters::Json.new }
    let(:formatter_sarif) { Docscribe::CLI::Formatters::Sarif.new }

    context 'when JSON source provided' do
      let(:syntax_offense) { json_offense_for('syntax') }
      let(:rbs_offense) { json_offense_for('rbs') }
      let(:infer_offense) { json_offense_for('infer') }

      it 'includes source syntax in JSON' do
        expect(syntax_offense['source']).to eq('syntax')
      end

      it 'includes source rbs in JSON' do
        expect(rbs_offense['source']).to eq('rbs')
      end

      it 'includes source infer in JSON' do
        expect(infer_offense['source']).to eq('infer')
      end
    end

    context 'when JSON source not provided' do
      let(:check_options) { { verbose: false, quiet: false, explain: false, mode: :check } }
      let(:state_without_source) do
        {
          changed: false, had_errors: false, checked_ok: 0, checked_fail: 1,
          corrected: 0, corrected_paths: [], corrected_changes: {},
          fail_paths: ['test.rb'],
          fail_changes: { 'test.rb' => [{ type: :missing_return, line: 5, method: 'Foo#bar', message: 'msg' }] },
          error_paths: [], error_messages: {},
          type_mismatch_paths: [], type_mismatch_changes: {}
        }
      end
      let(:parsed_json_without_source) do
        JSON.parse(capture_stdout { formatter_json.format_check_summary(state: state_without_source, options: check_options) })
      end
      let(:offense_without_source) { parsed_json_without_source['files'][0]['offenses'][0] }

      it 'omits source when not provided in JSON' do
        expect(offense_without_source).not_to have_key('source')
      end
    end

    context 'when SARIF source provided' do
      let(:syntax_result) { sarif_result_for('syntax') }
      let(:rbs_result) { sarif_result_for('rbs') }
      let(:infer_result) { sarif_result_for('infer') }

      it 'includes source syntax in SARIF properties' do
        expect(syntax_result['properties']['source']).to eq('syntax')
      end

      it 'includes source rbs in SARIF properties' do
        expect(rbs_result['properties']['source']).to eq('rbs')
      end

      it 'includes source infer in SARIF properties' do
        expect(infer_result['properties']['source']).to eq('infer')
      end
    end

    context 'when SARIF source not provided' do
      let(:sarif_options) { { verbose: false, quiet: false, explain: false, mode: :check, format: :sarif } }
      let(:state_without_source) do
        {
          changed: false, had_errors: false, checked_ok: 0, checked_fail: 1,
          corrected: 0, corrected_paths: [], corrected_changes: {},
          fail_paths: ['test.rb'],
          fail_changes: { 'test.rb' => [{ type: :missing_return, line: 5, method: 'Foo#bar', message: 'msg' }] },
          error_paths: [], error_messages: {},
          type_mismatch_paths: [], type_mismatch_changes: {}
        }
      end
      let(:parsed_sarif_without_source) do
        JSON.parse(capture_stdout { formatter_sarif.format_check_summary(state: state_without_source, options: sarif_options) })
      end
      let(:sarif_result_without_source) { parsed_sarif_without_source['runs'][0]['results'][0] }

      it 'omits properties when no source in SARIF' do
        expect(sarif_result_without_source).not_to have_key('properties')
      end
    end

    context 'when change type is invalid_type with JSON' do
      let(:invalid_state) do
        {
          changed: false, had_errors: false, checked_ok: 0, checked_fail: 1,
          corrected: 0, corrected_paths: [], corrected_changes: {},
          fail_paths: ['test.rb'],
          fail_changes: { 'test.rb' => [{ type: :invalid_type, line: 5, method: 'Foo#bar', source: 'syntax', message: 'invalid' }] },
          error_paths: [], error_messages: {},
          type_mismatch_paths: [], type_mismatch_changes: {}
        }
      end
      let(:check_options) { { verbose: false, quiet: false, explain: false, mode: :check } }
      let(:parsed_invalid_json) do
        JSON.parse(capture_stdout { formatter_json.format_check_summary(state: invalid_state, options: check_options) })
      end
      let(:invalid_offense) { parsed_invalid_json['files'][0]['offenses'][0] }

      it 'maps invalid_type to warning severity in JSON' do
        expect(invalid_offense['severity']).to eq('warning')
      end

      it 'maps invalid_type to Docscribe/InvalidType cop in JSON' do
        expect(invalid_offense['cop_name']).to eq('Docscribe/InvalidType')
      end

      it 'includes syntax source for invalid_type in JSON' do
        expect(invalid_offense['source']).to eq('syntax')
      end
    end

    context 'when change type is invalid_type with SARIF' do
      let(:invalid_state) do
        {
          changed: false, had_errors: false, checked_ok: 0, checked_fail: 1,
          corrected: 0, corrected_paths: [], corrected_changes: {},
          fail_paths: ['test.rb'],
          fail_changes: { 'test.rb' => [{ type: :invalid_type, line: 5, method: 'Foo#bar', source: 'syntax', message: 'invalid' }] },
          error_paths: [], error_messages: {},
          type_mismatch_paths: [], type_mismatch_changes: {}
        }
      end
      let(:sarif_options) { { verbose: false, quiet: false, explain: false, mode: :check, format: :sarif } }
      let(:parsed_invalid_sarif) do
        JSON.parse(capture_stdout { formatter_sarif.format_check_summary(state: invalid_state, options: sarif_options) })
      end
      let(:invalid_sarif_result) { parsed_invalid_sarif['runs'][0]['results'][0] }

      it 'maps invalid_type to warning level in SARIF' do
        expect(invalid_sarif_result['level']).to eq('warning')
      end

      it 'maps invalid_type to Docscribe/InvalidType rule in SARIF' do
        expect(invalid_sarif_result['ruleId']).to eq('Docscribe/InvalidType')
      end

      it 'includes syntax source for invalid_type in SARIF' do
        expect(invalid_sarif_result['properties']['source']).to eq('syntax')
      end
    end
  end

  describe 'daemon propagation via handle_check/run_rewrite' do
    let(:ruby_source_with_infer_mismatch) do
      <<~RUBY
        class Foo
          # @return [Integer]
          def bar
            "hello"
          end
        end
      RUBY
    end
    let(:daemon_cli_overrides) do
      {
        'validate_types' => true, 'include' => [], 'exclude' => [], 'include_file' => [], 'exclude_file' => [],
        'sig_dirs' => [], 'rbi_dirs' => [], 'no_boilerplate' => true
      }
    end

    context 'when daemon rewrites file with infer mismatch' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:infer_file) do
        File.write(File.join(tmp_dir, 'test.rb'), ruby_source_with_infer_mismatch)
        File.join(tmp_dir, 'test.rb')
      end
      let(:infer_daemon) do
        Docscribe::Server::Daemon.new(socket_path: File.join(tmp_dir, 'daemon.sock'), idle_timeout: 60).tap do |daemon|
          daemon.send(:load_dependencies)
          daemon.send(:apply_cli_overrides, daemon_cli_overrides)
        end
      end
      let(:infer_pair) do
        [
          infer_daemon.send(:rewrite_file, infer_file, :safe).last[:changes].find { |entry| entry[:type] == :updated_return },
          infer_daemon.send(:run_rewrite, infer_file, :safe)['changes'].find { |entry| entry['type'].to_s == 'updated_return' }
        ]
      end
      let(:infer_change) { infer_pair[0] }
      let(:infer_stringified) { infer_pair[1] }

      after { FileUtils.remove_entry(tmp_dir) }

      it 'returns infer change via daemon rewrite_file' do
        expect(infer_change).not_to be_nil
      end

      it 'returns infer source via daemon rewrite_file' do
        expect(infer_change[:source]).to eq('infer')
      end

      it 'returns stringified change via daemon run_rewrite' do
        expect(infer_stringified).not_to be_nil
      end

      it 'stringifies source as infer via daemon run_rewrite' do
        expect(infer_stringified['source']).to eq('infer')
      end
    end

    context 'when daemon handles batch with mixed sources' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:batch_first_file) do
        File.write(File.join(tmp_dir, 'a.rb'), "class A\n# @return [Integer]\ndef foo\n\"hi\"\nend\nend\n")
        File.join(tmp_dir, 'a.rb')
      end
      let(:batch_second_file) do
        File.write(File.join(tmp_dir, 'b.rb'), "class B\n# @return [Sym bol]\ndef bar\n:x\nend\nend\n")
        File.join(tmp_dir, 'b.rb')
      end
      let(:batch_daemon) do
        Docscribe::Server::Daemon.new(socket_path: File.join(tmp_dir, 'daemon2.sock'), idle_timeout: 60).tap do |daemon|
          daemon.send(:load_dependencies)
          daemon.send(:apply_cli_overrides, daemon_cli_overrides)
        end
      end
      let(:batch_first_src) do
        batch_daemon.send(:run_rewrite, batch_first_file, :safe)['changes'].find { |item| %w[updated_return invalid_type].include?(item['type'].to_s) }['source']
      end
      let(:batch_second_src) do
        batch_daemon.send(:run_rewrite, batch_second_file, :safe)['changes'].find { |item| item['type'].to_s == 'invalid_type' }['source']
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'returns infer source for first file in batch' do
        expect(batch_first_src).to eq('infer')
      end

      it 'returns syntax source for second file in batch' do
        expect(batch_second_src).to eq('syntax')
      end
    end
  end
end

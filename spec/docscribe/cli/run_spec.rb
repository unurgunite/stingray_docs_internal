# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'docscribe/cli'
require 'docscribe/server'

RSpec.describe Docscribe::CLI::Run do
  subject(:result) { Open3.capture3('ruby', exe, *args, chdir: dir) }

  let(:exe)      { File.expand_path('exe/docscribe') }
  let(:dir)      { Dir.mktmpdir }
  let(:code) do
    <<~RUBY
      class Foo
        def greet(name)
          "Hello, \#{name}"
        end

        def bar(x, y)
          x + y
        end
      end
    RUBY
  end

  before { File.write("#{dir}/foo.rb", code) }
  after  { FileUtils.remove_entry(dir) }

  describe 'check mode (default)' do
    let(:args) { ['foo.rb'] }

    it 'prints progress markers to stderr' do
      expect(result[1]).to include('F')
    end

    it 'prints Would update to stdout' do
      expect(result[0]).to match(/^Would update:/)
    end

    it 'does not print Would update to stderr' do
      expect(result[1]).not_to include('Would update')
    end

    it 'prints explanations before summary' do
      output = result[0]
      fail_idx = output.index('Would update:')
      status_idx = output.index('Docscribe:')
      expect(fail_idx).to be < status_idx
    end

    it 'prints change reasons' do
      expect(result[0]).to include('missing docs for Foo#bar')
    end

    it 'prints all change reasons' do
      expect(result[0]).to include('missing docs for Foo#greet')
    end

    it 'prints summary line' do
      expect(result[0]).to match(/Docscribe: (FAILED|OK)/)
    end

    it_behaves_like 'correct exit status'
  end

  describe 'check mode with --verbose' do
    let(:args) { %w[--verbose foo.rb] }

    it 'prints FAIL verdict per file to stderr' do
      expect(result[1]).to include('FAIL foo.rb')
    end

    it 'includes change reasons inline with verdict on stderr' do
      expect(result[1]).to match(/FAIL foo\.rb\n\s+- missing/)
    end

    it 'prints Would update without duplicating explanations' do
      output = result[0]
      after_would = output.split('Would update:').last || ''
      expect(after_would).not_to include('missing docs')
    end

    it 'prints summary line' do
      expect(result[0]).to match(/Docscribe: (FAILED|OK)/)
    end

    it 'outputs explanations to stderr' do
      expect(result[1]).to include('missing docs for Foo#bar')
    end

    it 'shows progress [N/total] on stderr' do
      expect(result[1]).to include('[1/1] foo.rb')
    end

    it_behaves_like 'correct exit status'
  end

  describe 'check mode with --progress' do
    let(:args) { %w[--progress foo.rb] }

    it 'shows progress [N/total] on stderr' do
      expect(result[1]).to include('[1/1] foo.rb')
    end

    it 'still prints progress markers to stderr alongside progress' do
      expect(result[1]).to include('[1/1]').and include('F')
    end

    it 'prints Would update to stdout' do
      expect(result[0]).to match(/^Would update:/)
    end

    it_behaves_like 'correct exit status'
  end

  describe 'check mode with --progress --quiet' do
    let(:args) { %w[--progress --quiet foo.rb] }

    it 'shows progress even when quiet' do
      expect(result[1]).to include('[1/1] foo.rb')
    end

    it 'prints Would update to stdout' do
      expect(result[0]).to match(/^Would update:/)
    end
  end

  describe 'write mode with --progress' do
    let(:args) { %w[--progress -a foo.rb] }

    it 'shows progress on stderr' do
      expect(result[1]).to include('[1/1] foo.rb')
    end

    it 'prints C marker to stderr' do
      expect(result[1]).to include('C')
    end

    it 'prints update summary to stdout' do
      expect(result[0]).to match(/updated \d+ file/)
    end

    it 'exits 0' do
      expect(result[2].exitstatus).to eq(0)
    end
  end

  describe 'check mode with --explain' do
    let(:args) { %w[--explain foo.rb] }

    it 'prints change reasons in summary (same as default)' do
      expect(result[0]).to include('missing docs for Foo#bar')
    end

    it 'prints Would update before summary' do
      output = result[0]
      fail_idx = output.index('Would update:')
      status_idx = output.index('Docscribe:')
      expect(fail_idx).to be < status_idx
    end

    it_behaves_like 'correct exit status'
  end

  describe 'check mode with --quiet' do
    let(:args) { %w[--quiet foo.rb] }

    it 'prints Would update to stdout' do
      expect(result[0]).to match(/^Would update:/)
    end

    it 'does not print change reasons in summary' do
      output = result[0]
      expect(output).not_to include('missing docs')
    end

    it_behaves_like 'correct exit status'
  end

  describe 'write mode with --quiet' do
    let(:args) { %w[-a --quiet foo.rb] }

    it 'prints C marker to stderr' do
      expect(result[1]).to include('C')
    end

    it 'prints Updated:' do
      expect(result[0]).to include('Updated:')
    end

    it 'does not print change reasons in write mode' do
      expect(result[0]).not_to include('missing docs')
    end

    it 'prints update summary to stdout' do
      expect(result[0]).to match(/updated \d+ file/)
    end

    it 'exits 0' do
      expect(result[2].exitstatus).to eq(0)
    end
  end

  describe 'write mode' do
    let(:args) { %w[-a foo.rb] }

    it 'prints C marker to stderr' do
      expect(result[1]).to include('C')
    end

    it 'prints update summary to stdout' do
      expect(result[0]).to match(/updated \d+ file/)
    end

    it 'prints Updated: per corrected file' do
      expect(result[0]).to include('Updated:')
    end

    it 'prints change reasons with Updated:' do
      expect(result[0]).to match(/Updated: .*\n\s+- missing/)
    end

    it 'exits 0' do
      expect(result[2].exitstatus).to eq(0)
    end

    it 'actually writes docs to file' do
      Open3.capture3('ruby', exe, '-a', 'foo.rb', chdir: dir)
      content = File.read("#{dir}/foo.rb")
      expect(content).to include('@param [Object] name')
    end
  end

  describe 'write mode with --verbose' do
    let(:args) { %w[-a --verbose foo.rb] }

    it 'prints CHANGED verdict with explanations to stderr' do
      expect(result[1]).to match(/CHANGED foo\.rb\n\s+- missing/)
    end

    it 'prints update summary to stdout' do
      expect(result[0]).to match(/updated \d+ file/)
    end

    it 'prints Updated: without duplicating reasons' do
      after_updated = result[0].split('Updated:').last || ''
      expect(after_updated).not_to include('missing docs')
    end
  end

  describe 'with --format json' do
    let(:args) { %w[--format json foo.rb] }

    it 'outputs valid JSON to stdout' do
      expect { JSON.parse(result[0]) }.not_to raise_error
    end

    it 'includes metadata in JSON' do
      parsed = JSON.parse(result[0])
      expect(parsed['metadata']).to include('docscribe_version', 'ruby_version')
    end

    it 'includes files array in JSON' do
      expect(JSON.parse(result[0])['files']).to be_an(Array)
    end

    it 'includes offenses in first file' do
      expect(JSON.parse(result[0])['files'][0]['offenses']).not_to be_empty
    end

    it 'includes summary in JSON' do
      parsed = JSON.parse(result[0])
      expect(parsed['summary']).to include('offense_count', 'target_file_count', 'inspected_file_count')
    end

    it 'has correct cop_name in offenses' do
      offenses = JSON.parse(result[0])['files'].flat_map { |f| f['offenses'] }
      expect(offenses.first['cop_name']).to match(%r{\ADocscribe/})
    end

    it 'still sends progress markers to stderr' do
      expect(result[1]).to include('F')
    end

    it 'exits 1 with findings' do
      expect(result[2].exitstatus).to eq(1)
    end

    it 'does not contain Would update on stdout' do
      expect(result[0]).not_to include('Would update:')
    end

    it 'does not contain Docscribe: summary on stdout' do
      expect(result[0]).not_to include('Docscribe:')
    end
  end

  describe 'with --format json --verbose' do
    let(:args) { %w[--format json --verbose foo.rb] }

    it 'still outputs JSON to stdout' do
      expect { JSON.parse(result[0]) }.not_to raise_error
    end

    it 'prints FAIL verdict to stderr' do
      expect(result[1]).to include('FAIL foo.rb')
    end
  end

  describe 'with --format json --quiet' do
    let(:args) { %w[--format json --quiet foo.rb] }

    it 'does not contain Would update on stdout' do
      expect(result[0]).not_to include('Would update:')
    end

    it 'does not contain Docscribe: summary on stdout' do
      expect(result[0]).not_to include('Docscribe:')
    end
  end

  describe 'with --format json in write mode' do
    let(:args) { %w[--format json -a foo.rb] }

    it 'outputs valid JSON to stdout' do
      expect { JSON.parse(result[0]) }.not_to raise_error
    end

    it 'includes one file in JSON' do
      expect(JSON.parse(result[0])['files'].size).to eq(1)
    end

    it 'has correct file path' do
      expect(JSON.parse(result[0])['files'][0]['path']).to eq('foo.rb')
    end

    it 'exits 0' do
      expect(result[2].exitstatus).to eq(0)
    end

    it 'sends C progress to stderr' do
      expect(result[1]).to include('C')
    end
  end

  describe 'with --format json when all files fine' do
    let(:code) { <<~RUBY }
      # documented
      class Foo; end
    RUBY

    let(:args) { %w[--format json foo.rb] }

    it 'outputs JSON with empty files' do
      parsed = JSON.parse(result[0])
      expect(parsed['files']).to eq([])
    end

    it 'outputs OK status in JSON summary' do
      parsed = JSON.parse(result[0])
      expect(parsed['summary']['offense_count']).to eq(0)
    end

    it 'exits 0' do
      expect(result[2].exitstatus).to eq(0)
    end
  end

  context 'when all files are fine' do
    let(:code) { <<~RUBY }
      # documentation
      class Foo; end
    RUBY

    let(:args) { ['foo.rb'] }

    it 'prints dot marker to stderr' do
      expect(result[1]).to include('.')
    end

    it 'prints OK summary to stdout' do
      expect(result[0]).to include('Docscribe: OK')
    end

    it 'exits 0' do
      expect(result[2].exitstatus).to eq(0)
    end
  end

  describe '.ensure_server_running!' do
    it 'delegates to Docscribe::Server.ensure_running!' do
      allow(Docscribe::Server).to receive(:ensure_running!)
      described_class.send(:ensure_server_running!, config_path: nil)
      expect(Docscribe::Server).to have_received(:ensure_running!).with(config_path: nil)
    end
  end

  describe '.extract_cli_overrides' do
    context 'when options contain false values' do
      subject(:overrides) { described_class.send(:extract_cli_overrides, options) }

      let(:options) { { keep_descriptions: true, no_boilerplate: false, rbs: false, validate_types: false } }

      it 'filters false values', :aggregate_failures do
        expect(overrides).not_to have_key('no_boilerplate')
        expect(overrides).not_to have_key('rbs')
        expect(overrides).not_to have_key('validate_types')
      end

      it 'keeps true values' do
        expect(overrides).to have_key('keep_descriptions')
        expect(overrides['keep_descriptions']).to be(true)
      end
    end

    context 'when options contain nil values' do
      subject(:overrides) { described_class.send(:extract_cli_overrides, options) }

      let(:options) { { keep_descriptions: nil, no_boilerplate: true, rbs: nil } }

      it 'filters nil values' do
        expect(overrides).not_to have_key('keep_descriptions')
        expect(overrides).not_to have_key('rbs')
      end

      it 'keeps non-nil true' do
        expect(overrides['no_boilerplate']).to be(true)
      end
    end

    context 'when options contain empty arrays' do
      subject(:overrides) { described_class.send(:extract_cli_overrides, options) }

      let(:options) { { include: [], exclude: [], sig_dirs: [], include_file: ['a.rb'], exclude_file: [] } }

      it 'filters empty arrays', :aggregate_failures do
        expect(overrides).not_to have_key('include')
        expect(overrides).not_to have_key('exclude')
        expect(overrides).not_to have_key('sig_dirs')
        expect(overrides).not_to have_key('exclude_file')
      end

      it 'keeps non-empty arrays' do
        expect(overrides['include_file']).to eq(['a.rb'])
      end
    end

    context 'when options contain valid arrays' do
      subject(:overrides) { described_class.send(:extract_cli_overrides, options) }

      let(:options) { { include: ['lib/**/*.rb'], exclude: ['spec/**/*'], sig_dirs: ['sig'], rbi_dirs: ['sorbet/rbi'] } }

      it 'keeps valid arrays', :aggregate_failures do
        expect(overrides['include']).to eq(['lib/**/*.rb'])
        expect(overrides['exclude']).to eq(['spec/**/*'])
        expect(overrides['sig_dirs']).to eq(['sig'])
        expect(overrides['rbi_dirs']).to eq(['sorbet/rbi'])
      end
    end

    context 'when options contain non-override keys' do
      subject(:overrides) { described_class.send(:extract_cli_overrides, options) }

      let(:options) { { keep_descriptions: true, unrelated: 'value', mode: :check } }

      it 'slices only CLI_OVERRIDE_KEYS', :aggregate_failures do
        expect(overrides).to have_key('keep_descriptions')
        expect(overrides).not_to have_key('unrelated')
        expect(overrides).not_to have_key('mode')
      end
    end

    context 'when options are mixed' do
      subject(:overrides) { described_class.send(:extract_cli_overrides, options) }

      let(:options) do
        {
          keep_descriptions: true,
          no_boilerplate: false,
          include: [],
          exclude: ['excluded.rb'],
          rbs: true,
          rbs_collection: false,
          sig_dirs: ['sig'],
          sorbet: nil,
          rbi_dirs: [],
          validate_types: true
        }
      end

      it 'correctly filters and keeps', :aggregate_failures do
        expect(overrides).to include('keep_descriptions' => true, 'exclude' => ['excluded.rb'], 'rbs' => true, 'sig_dirs' => ['sig'], 'validate_types' => true)
        expect(overrides).not_to have_key('no_boilerplate')
        expect(overrides).not_to have_key('include')
        expect(overrides).not_to have_key('rbs_collection')
        expect(overrides).not_to have_key('sorbet')
        expect(overrides).not_to have_key('rbi_dirs')
      end

      it 'stringifies keys' do
        expect(overrides.keys).to all(be_a(String))
      end
    end

    context 'when options are empty' do
      subject(:overrides) { described_class.send(:extract_cli_overrides, options) }

      let(:options) { {} }

      it 'returns empty hash' do
        expect(overrides).to eq({})
      end
    end

    context 'when options contain empty string vs false' do
      subject(:overrides) { described_class.send(:extract_cli_overrides, options) }

      let(:options) { { keep_descriptions: '', rbs: false } }

      it 'keeps empty string but filters false', :aggregate_failures do
        expect(overrides).to have_key('keep_descriptions')
        expect(overrides['keep_descriptions']).to eq('')
        expect(overrides).not_to have_key('rbs')
      end
    end
  end
end

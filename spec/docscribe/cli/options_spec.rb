# frozen_string_literal: true

require 'docscribe/cli/options'

RSpec.describe Docscribe::CLI::Options do
  it 'routes /regex/ passed to --include into method filters (not file filters)', :aggregate_failures do
    argv = %w[--include /^A#foo$/ lib]
    opts = described_class.parse!(argv)

    expect(opts[:include]).to eq(['/^A#foo$/'])
    expect(opts[:include_file]).to eq([])
  end

  it 'routes /regex/ passed to --exclude into method filters (not file filters)', :aggregate_failures do
    argv = %w[--exclude /^A#foo$/ lib]
    opts = described_class.parse!(argv)

    expect(opts[:exclude]).to eq(['/^A#foo$/'])
    expect(opts[:exclude_file]).to eq([])
  end

  it 'uses inspect-safe mode by default', :aggregate_failures do
    opts = described_class.parse!(%w[lib])

    expect(opts[:mode]).to eq(:check)
    expect(opts[:strategy]).to eq(:safe)
  end

  it 'uses safe write mode for -a', :aggregate_failures do
    opts = described_class.parse!(%w[-a lib])

    expect(opts[:mode]).to eq(:write)
    expect(opts[:strategy]).to eq(:safe)
  end

  it 'uses aggressive write mode for -A', :aggregate_failures do
    opts = described_class.parse!(%w[-A lib])

    expect(opts[:mode]).to eq(:write)
    expect(opts[:strategy]).to eq(:aggressive)
  end

  it 'uses stdin mode with safe strategy by default', :aggregate_failures do
    opts = described_class.parse!(%w[--stdin])

    expect(opts[:mode]).to eq(:stdin)
    expect(opts[:strategy]).to eq(:safe)
  end

  it 'uses stdin mode with aggressive strategy for -A --stdin', :aggregate_failures do
    opts = described_class.parse!(%w[-A --stdin])

    expect(opts[:mode]).to eq(:stdin)
    expect(opts[:strategy]).to eq(:aggressive)
  end

  it 'enables Sorbet with --sorbet', :aggregate_failures do
    opts = described_class.parse!(%w[--sorbet lib])

    expect(opts[:sorbet]).to be(true)
    expect(opts[:rbi_dirs]).to eq([])
  end

  it 'adds RBI dirs and implies Sorbet with --rbi-dir', :aggregate_failures do
    opts = described_class.parse!(%w[--rbi-dir sorbet/rbi --rbi-dir rbi lib])

    expect(opts[:sorbet]).to be(true)
    expect(opts[:rbi_dirs]).to eq(%w[sorbet/rbi rbi])
  end

  it 'sets no_boilerplate with -B', :aggregate_failures do
    opts = described_class.parse!(%w[-B lib])

    expect(opts[:no_boilerplate]).to be(true)
  end

  it 'sets no_boilerplate with --no-boilerplate', :aggregate_failures do
    opts = described_class.parse!(%w[--no-boilerplate lib])

    expect(opts[:no_boilerplate]).to be(true)
  end

  it 'combines -A -k -B without error', :aggregate_failures do
    opts = described_class.parse!(%w[-AkB lib])

    expect(opts[:mode]).to eq(:write)
    expect(opts[:strategy]).to eq(:aggressive)
    expect(opts[:keep_descriptions]).to be(true)
    expect(opts[:no_boilerplate]).to be(true)
  end

  it 'sets explain with --explain', :aggregate_failures do
    opts = described_class.parse!(%w[--explain lib])

    expect(opts[:explain]).to be(true)
    expect(opts[:quiet]).to be(false)
  end

  it 'sets quiet with --quiet', :aggregate_failures do
    opts = described_class.parse!(%w[--quiet lib])

    expect(opts[:quiet]).to be(true)
    expect(opts[:explain]).to be(false)
  end

  it 'parses -q as quiet' do
    opts = described_class.parse!(%w[-q lib])

    expect(opts[:quiet]).to be(true)
  end

  it 'quiet and explain can coexist' do
    opts = described_class.parse!(%w[--quiet --explain lib])
    expect(opts[:quiet]).to be(true)
  end

  it 'quiet and explain can coexist (explain)' do
    opts = described_class.parse!(%w[--quiet --explain lib])
    expect(opts[:explain]).to be(true)
  end

  it 'parses --progress flag' do
    opts = described_class.parse!(%w[--progress lib])
    expect(opts[:progress]).to be(true)
  end

  it 'does not set progress by default' do
    opts = described_class.parse!(%w[lib])
    expect(opts[:progress]).to be(false)
  end

  it 'auto-enables progress with --verbose' do
    opts = described_class.parse!(%w[--verbose lib])
    expect(opts).to include(progress: true, verbose: true)
  end

  describe '.define_validate_types_option' do
    let(:options) { Marshal.load(Marshal.dump(described_class::DEFAULT)) }
    let(:parser) { described_class.build_option_parser(options, { mode: nil }) }

    it 'sets validate_types true for --validate-types' do
      parser.parse!(%w[--validate-types])
      expect(options[:validate_types]).to be(true)
    end

    it 'sets validate_types false for --no-validate-types' do
      parser.parse!(%w[--no-validate-types])
      expect(options[:validate_types]).to be(false)
    end
  end

  it 'sets validate_types true for --validate-types via parse!' do
    opts = described_class.parse!(%w[--validate-types lib])
    expect(opts[:validate_types]).to be(true)
  end

  it 'sets validate_types false for --no-validate-types via parse!', :aggregate_failures do
    opts = described_class.parse!(%w[--no-validate-types lib])
    expect(opts[:validate_types]).to be(false)
    expect(opts[:rbs]).to be(false)
  end

  it 'defaults validate_types to false' do
    opts = described_class.parse!(%w[lib])
    expect(opts[:validate_types]).to be(false)
  end

  it 'last flag wins for repeated validate-types', :aggregate_failures do
    opts = described_class.parse!(%w[--validate-types --no-validate-types lib])
    expect(opts[:validate_types]).to be(false)
  end
end

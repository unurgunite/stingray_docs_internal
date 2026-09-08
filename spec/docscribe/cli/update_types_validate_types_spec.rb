# frozen_string_literal: true

# rubocop:disable RSpec/MultipleDescribes, RSpec/ReceiveMessages

require 'tmpdir'
require 'fileutils'
require 'docscribe/cli/update_types'
require 'docscribe/cli/options'
require 'docscribe/cli/config_builder'
require 'docscribe/config'

RSpec.describe Docscribe::CLI::UpdateTypes do
  describe '.parse_options extra_argv forwarding' do
    let(:parsed) { described_class.send(:parse_options, argv.dup) }

    context 'when --validate-types passed' do
      let(:argv) { ['--validate-types', 'lib'] }

      it 'includes --validate-types in extra_argv', :aggregate_failures do
        expect(parsed[:extra_argv]).to include('--validate-types')
        expect(parsed[:dir]).to eq('lib')
      end

      it 'does not include --no-validate-types' do
        expect(parsed[:extra_argv]).not_to include('--no-validate-types')
      end
    end

    context 'when --no-validate-types passed' do
      let(:argv) { ['--no-validate-types', 'lib'] }

      it 'includes --no-validate-types and not --validate-types', :aggregate_failures do
        expect(parsed[:extra_argv]).to include('--no-validate-types')
        expect(parsed[:extra_argv]).not_to include('--validate-types')
        expect(parsed[:dir]).to eq('lib')
      end
    end

    context 'when --rbs and --validate-types passed' do
      let(:argv) { ['--rbs', '--validate-types', 'lib'] }

      it 'forwards both flags', :aggregate_failures do
        expect(parsed[:extra_argv]).to include('--rbs')
        expect(parsed[:extra_argv]).to include('--validate-types')
        expect(parsed[:extra_argv].count('--rbs')).to eq(1)
        expect(parsed[:extra_argv].count('--validate-types')).to eq(1)
      end

      it 'sets dir correctly without duplication', :aggregate_failures do
        expect(parsed[:dir]).to eq('lib')
        expect(parsed[:extra_argv].count('lib')).to eq(0)
      end
    end

    context 'when --sig-dir and --validate-types passed' do
      let(:argv) { ['--sig-dir', 'sig', '--validate-types', 'lib'] }

      it 'forwards all type flags', :aggregate_failures do
        expect(parsed[:extra_argv]).to include('--sig-dir')
        expect(parsed[:extra_argv]).to include('sig')
        expect(parsed[:extra_argv]).to include('--validate-types')
        expect(parsed[:dir]).to eq('lib')
      end
    end

    context 'when --rbs-collection and --validate-types passed' do
      let(:argv) { ['--rbs-collection', '--validate-types', 'lib'] }

      it 'forwards both collection and validate flags', :aggregate_failures do
        expect(parsed[:extra_argv]).to include('--rbs-collection')
        expect(parsed[:extra_argv]).to include('--validate-types')
      end
    end

    context 'when bare --validate-types without dir' do
      let(:argv) { ['--validate-types'] }

      it 'defaults dir to . and forwards flag', :aggregate_failures do
        expect(parsed[:extra_argv]).to include('--validate-types')
        expect(parsed[:dir]).to eq('.')
      end
    end
  end

  describe '.run_first_pass filtering and dir forwarding' do
    let(:default_options) { Docscribe::CLI::Options::DEFAULT.dup }
    let(:aggressive_options) do
      default_options.merge(mode: :write, strategy: :aggressive, rbs: true, rbs_collection: false, no_boilerplate: true, keep_descriptions: true)
    end
    let(:captured_argv) { [] }
    let(:tmp_dir) { Dir.mktmpdir }

    before do
      allow(Docscribe::CLI::Options).to receive(:parse!) do |argv|
        captured_argv.replace(argv)
        aggressive_options
      end
      allow(Docscribe::CLI::Run).to receive(:run).and_return(0)
      allow(File).to receive(:file?).and_return(false)
      allow(File).to receive(:exist?).and_return(false)
    end

    after do
      FileUtils.rm_rf(tmp_dir)
      described_class.instance_variable_set(:@extra_argv, [])
    end

    context 'when extra_argv includes --validate-types' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--validate-types'])
        described_class.send(:run_first_pass, tmp_dir)
      end

      it 'forwards --validate-types to Options.parse!', :aggregate_failures do
        expect(captured_argv).to include('--validate-types')
        expect(captured_argv).to include('-AkB')
      end

      it 'passes dir_for_flag once to Options.parse!' do
        expect(captured_argv.count(tmp_dir)).to eq(1)
      end

      it 'passes original target to Run.run', :aggregate_failures do
        expect(Docscribe::CLI::Run).to have_received(:run).with(options: hash_including(strategy: :aggressive), argv: [tmp_dir])
      end

      it 'includes default --rbs when no explicit rbs flag' do
        expect(captured_argv).to include('--rbs')
      end
    end

    context 'when extra_argv includes --no-validate-types' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--no-validate-types'])
        described_class.send(:run_first_pass, tmp_dir)
      end

      it 'filters --no-validate-types from Options.parse!', :aggregate_failures do
        expect(captured_argv).not_to include('--no-validate-types')
        expect(captured_argv).not_to include('--validate-types')
      end

      it 'still forwards default rbs flag and dir' do
        expect(captured_argv).to include('--rbs')
        expect(captured_argv.count(tmp_dir)).to eq(1)
      end

      it 'does not include --no-validate-types in any position' do
        expect(captured_argv.grep(/validate-types/)).to be_empty
      end
    end

    context 'when extra_argv includes --no-rbs' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--no-rbs'])
        described_class.send(:run_first_pass, tmp_dir)
      end

      it 'filters --no-rbs and does not add dir_for_flag', :aggregate_failures do
        expect(captured_argv).not_to include('--no-rbs')
        expect(captured_argv).not_to include('--rbs')
        expect(captured_argv).not_to include('--rbs-collection')
        expect(captured_argv).not_to include(tmp_dir)
        expect(captured_argv).to eq(['-AkB'])
      end

      it 'still passes target to Run.run' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(argv: [tmp_dir], options: anything)
      end
    end

    context 'when extra_argv includes --no-rbs and --no-validate-types' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--no-rbs', '--no-validate-types'])
        described_class.send(:run_first_pass, tmp_dir)
      end

      it 'filters both negated flags', :aggregate_failures do
        expect(captured_argv).not_to include('--no-rbs')
        expect(captured_argv).not_to include('--no-validate-types')
        expect(captured_argv).not_to include(tmp_dir)
      end
    end

    context 'when extra_argv includes --rbs and --validate-types' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--rbs', '--validate-types'])
        described_class.send(:run_first_pass, tmp_dir)
      end

      it 'forwards both flags and includes dir once', :aggregate_failures do
        expect(captured_argv).to include('--rbs')
        expect(captured_argv).to include('--validate-types')
        expect(captured_argv.count('--rbs')).to eq(1)
        expect(captured_argv.count('--validate-types')).to eq(1)
        expect(captured_argv.count(tmp_dir)).to eq(1)
      end

      it 'does not duplicate dir_for_flag', :aggregate_failures do
        expect(captured_argv.count(tmp_dir)).to eq(1)
        expect(captured_argv).to include('-AkB')
      end

      it 'passes correct argv ordering prefix' do
        expect(captured_argv.first).to eq('-AkB')
      end
    end

    context 'when extra_argv includes --rbs with explicit dir duplication guard' do
      let(:sig_dir_value) { tmp_dir }

      before do
        described_class.instance_variable_set(:@extra_argv, ['--sig-dir', sig_dir_value, '--validate-types'])
        # has_rbs_flag false for --sig-dir, so branch uses default flag + dir
        # but we test --rbs case duplication guard: --rbs already present should not duplicate dir
        described_class.instance_variable_set(:@extra_argv, ['--rbs', '--validate-types'])
        described_class.send(:run_first_pass, tmp_dir)
      end

      it 'does not duplicate dir_for_flag when already present' do
        expect(captured_argv.count(tmp_dir)).to eq(1)
      end
    end

    context 'when target is a file' do
      let(:target_file) do
        path = File.join(tmp_dir, 'foo.rb')
        FileUtils.touch(path)
        path
      end
      let(:dir_for_flag) { File.dirname(target_file) }

      before do
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with(target_file).and_return(true)
        allow(File).to receive(:file?).with(tmp_dir).and_return(false)
        allow(File).to receive(:exist?).and_return(false)
        described_class.instance_variable_set(:@extra_argv, ['--validate-types'])
        described_class.send(:run_first_pass, target_file)
      end

      it 'passes dirname to Options.parse! and file to Run.run', :aggregate_failures do
        expect(captured_argv).to include(dir_for_flag)
        expect(captured_argv).not_to include(target_file)
        expect(Docscribe::CLI::Run).to have_received(:run).with(argv: [target_file], options: anything)
      end

      it 'forwards --validate-types' do
        expect(captured_argv).to include('--validate-types')
      end
    end

    context 'when has_collection true via parse_options' do
      let(:argv) { ['--validate-types', tmp_dir] }
      let(:parsed_extra) { described_class.send(:parse_options, argv.dup)[:extra_argv] }

      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(File.join(tmp_dir, 'rbs_collection.lock.yaml')).and_return(true)
        allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(false)
        allow(File).to receive(:file?).and_return(false)
        described_class.instance_variable_set(:@extra_argv, parsed_extra)
        described_class.send(:run_first_pass, tmp_dir)
      end

      it 'uses --rbs-collection and forwards validate', :aggregate_failures do
        expect(captured_argv).to include('--rbs-collection')
        expect(captured_argv).to include('--validate-types')
        expect(captured_argv).not_to include('--rbs')
      end
    end
  end

  describe '.run_second_pass filtering and dir forwarding' do
    let(:default_options) { Docscribe::CLI::Options::DEFAULT.dup }
    let(:safe_options) do
      default_options.merge(mode: :write, strategy: :safe, rbs: true, rbs_collection: false, no_boilerplate: true)
    end
    let(:captured_argv) { [] }
    let(:tmp_dir) { Dir.mktmpdir }

    before do
      allow(Docscribe::CLI::Options).to receive(:parse!) do |argv|
        captured_argv.replace(argv)
        safe_options
      end
      allow(Docscribe::CLI::Run).to receive(:run).and_return(0)
      allow(File).to receive(:file?).and_return(false)
      allow(File).to receive(:exist?).and_return(false)
    end

    after do
      FileUtils.rm_rf(tmp_dir)
      described_class.instance_variable_set(:@extra_argv, [])
    end

    context 'when extra_argv includes --validate-types' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--validate-types'])
        described_class.send(:run_second_pass, tmp_dir)
      end

      it 'forwards --validate-types with -aB', :aggregate_failures do
        expect(captured_argv).to include('-aB')
        expect(captured_argv).to include('--validate-types')
        expect(captured_argv.count(tmp_dir)).to eq(1)
      end

      it 'passes original target to Run.run' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(options: hash_including(strategy: :safe), argv: [tmp_dir])
      end
    end

    context 'when extra_argv includes --no-validate-types' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--no-validate-types'])
        described_class.send(:run_second_pass, tmp_dir)
      end

      it 'filters --no-validate-types', :aggregate_failures do
        expect(captured_argv).not_to include('--no-validate-types')
        expect(captured_argv.grep(/validate-types/)).to be_empty
        expect(captured_argv.count(tmp_dir)).to eq(1)
      end
    end

    context 'when extra_argv includes --no-rbs' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--no-rbs'])
        described_class.send(:run_second_pass, tmp_dir)
      end

      it 'filters --no-rbs and does not add rbs dir', :aggregate_failures do
        expect(captured_argv).not_to include('--no-rbs')
        expect(captured_argv).not_to include(tmp_dir)
        expect(captured_argv).to eq(['-aB'])
      end
    end

    context 'when extra_argv includes --rbs and --validate-types' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--rbs', '--validate-types'])
        described_class.send(:run_second_pass, tmp_dir)
      end

      it 'forwards both without duplication', :aggregate_failures do
        expect(captured_argv).to include('--rbs')
        expect(captured_argv).to include('--validate-types')
        expect(captured_argv.count('--rbs')).to eq(1)
        expect(captured_argv.count('--validate-types')).to eq(1)
        expect(captured_argv.count(tmp_dir)).to eq(1)
        expect(captured_argv.first).to eq('-aB')
      end
    end

    context 'when target is file with --validate-types' do
      let(:target_file) do
        path = File.join(tmp_dir, 'bar.rb')
        FileUtils.touch(path)
        path
      end
      let(:dir_for_flag) { File.dirname(target_file) }

      before do
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with(target_file).and_return(true)
        allow(File).to receive(:file?).with(tmp_dir).and_return(false)
        described_class.instance_variable_set(:@extra_argv, ['--validate-types'])
        described_class.send(:run_second_pass, target_file)
      end

      it 'passes dirname to parse and file to Run', :aggregate_failures do
        expect(captured_argv).to include(dir_for_flag)
        expect(captured_argv).not_to include(target_file)
        expect(Docscribe::CLI::Run).to have_received(:run).with(argv: [target_file], options: hash_including(strategy: :safe))
      end
    end

    context 'when collection exists' do
      before do
        allow(File).to receive(:exist?).and_return(true)
        described_class.instance_variable_set(:@extra_argv, ['--validate-types'])
        described_class.send(:run_second_pass, tmp_dir)
      end

      it 'uses --rbs-collection with validate-types', :aggregate_failures do
        expect(captured_argv).to include('--rbs-collection')
        expect(captured_argv).to include('--validate-types')
      end
    end

    context 'when --rbs already includes dir value' do
      before do
        described_class.instance_variable_set(:@extra_argv, ['--rbs', '--validate-types'])
        # simulate parse_options where dir already part of extra? Actually lib dir passed separately.
        # We verify guard `argv1.include?(dir_for_flag)` prevents duplication when dir already in argv.
        # Manually craft extra that already contains dir_for_flag as value for another flag is not relevant;
        # but has_rbs_flag path checks for existing dir in argv, so second addition skipped.
        # To trigger duplication guard we set extra_argv to include dir_for_flag itself (edge)
        described_class.instance_variable_set(:@extra_argv, ['--rbs', tmp_dir, '--validate-types'])
        captured_argv.clear
        described_class.send(:run_second_pass, tmp_dir)
      end

      it 'does not duplicate dir_for_flag when already in argv' do
        expect(captured_argv.count(tmp_dir)).to eq(1)
      end
    end
  end

  describe '.run integration with --validate-types' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:target_file) do
      path = File.join(tmp_dir, 'a.rb')
      File.write(path, "class A\ndef foo\n1\nend\nend\n")
      path
    end

    after { FileUtils.rm_rf(tmp_dir) }

    it 'passes file to both passes via parse_options forwarding' do
      allow(described_class).to receive(:run_first_pass).and_return(0)
      allow(described_class).to receive(:run_second_pass).and_return(0)
      described_class.run(['--validate-types', target_file])
      expect(described_class).to have_received(:run_first_pass).with(target_file)
      expect(described_class).to have_received(:run_second_pass).with(target_file)
    end

    it 'stores extra_argv includes --validate-types after parse_options' do
      parsed = described_class.send(:parse_options, ['--validate-types', tmp_dir])
      expect(parsed[:extra_argv]).to include('--validate-types')
    end
  end
end

RSpec.describe Docscribe::CLI::ConfigBuilder do
  let(:default_options) { Docscribe::CLI::Options::DEFAULT }

  describe '.validation_overrides?' do
    it 'returns false for default options' do
      expect(described_class.validation_overrides?(default_options)).to be(false)
    end

    it 'returns false when validate_types false' do
      opts = default_options.merge(validate_types: false)
      expect(described_class.validation_overrides?(opts)).to be(false)
    end

    it 'returns true when validate_types true' do
      opts = default_options.merge(validate_types: true)
      expect(described_class.validation_overrides?(opts)).to be(true)
    end

    it 'returns false when validate_types nil' do
      opts = default_options.merge(validate_types: nil)
      expect(described_class.validation_overrides?(opts)).to be(false)
    end
  end

  describe '.apply_validation_overrides' do
    let(:raw) { {} }

    it 'sets validate_types to true when option true' do
      described_class.apply_validation_overrides(raw, default_options.merge(validate_types: true))
      expect(raw['validate_types']).to be(true)
    end

    it 'does not set validate_types when false' do
      described_class.apply_validation_overrides(raw, default_options.merge(validate_types: false))
      expect(raw).not_to have_key('validate_types')
    end

    it 'does not overwrite when false and raw already true', :aggregate_failures do
      raw['validate_types'] = true
      described_class.apply_validation_overrides(raw, default_options.merge(validate_types: false))
      expect(raw['validate_types']).to be(true)
    end

    it 'preserves other raw keys', :aggregate_failures do
      raw['emit'] = { 'include_default_message' => true }
      described_class.apply_validation_overrides(raw, default_options.merge(validate_types: true))
      expect(raw['emit']).to eq({ 'include_default_message' => true })
      expect(raw['validate_types']).to be(true)
    end
  end

  describe '.needs_override? with validate_types' do
    it 'returns true when validate_types true' do
      opts = default_options.merge(validate_types: true)
      expect(described_class.needs_override?(opts)).to be(true)
    end

    it 'returns false when validate_types false' do
      opts = default_options.merge(validate_types: false)
      expect(described_class.needs_override?(opts)).to be(false)
    end
  end

  describe '.build with validation overrides' do
    let(:base) { Docscribe::Config.new(config_path: '/tmp/test.yml') }

    it 'sets validate_types true via build when option true', :aggregate_failures do
      opts = default_options.merge(validate_types: true)
      config = described_class.build(base, opts)
      expect(config.raw['validate_types']).to be(true)
      expect(config.validate_types?).to be(true)
    end

    it 'does not set validate_types via build when false' do
      opts = default_options.merge(validate_types: false)
      config = described_class.build(base, opts)
      expect(config.raw['validate_types']).to be(false)
      expect(config.validate_types?).to be(false)
    end

    it 'returns base unchanged when no validation override and no other overrides' do
      config = described_class.build(base, default_options)
      expect(config).to equal(base)
    end

    it 'does not mutate base raw' do
      opts = default_options.merge(validate_types: true)
      original = Marshal.load(Marshal.dump(base.raw))
      described_class.build(base, opts)
      expect(base.raw).to eq(original)
    end
  end
end

RSpec.describe Docscribe::CLI::Options do
  describe '.define_validate_types_option' do
    let(:options) { Marshal.load(Marshal.dump(described_class::DEFAULT)) }
    let(:parser) do
      described_class.build_option_parser(options, { mode: nil })
    end

    it 'parses --validate-types via define_validate_types_option' do
      parser.parse!(%w[--validate-types])
      expect(options[:validate_types]).to be(true)
    end

    it 'parses --no-validate-types via define_validate_types_option' do
      parser.parse!(%w[--no-validate-types])
      expect(options[:validate_types]).to be(false)
    end
  end

  describe '.parse! validate_types' do
    it 'defaults validate_types to false' do
      opts = described_class.parse!(%w[lib])
      expect(opts[:validate_types]).to be(false)
    end

    it 'sets true for --validate-types' do
      opts = described_class.parse!(%w[--validate-types lib])
      expect(opts[:validate_types]).to be(true)
    end

    it 'sets false for --no-validate-types', :aggregate_failures do
      opts = described_class.parse!(%w[--no-validate-types lib])
      expect(opts[:validate_types]).to be(false)
      expect(opts[:rbs]).to be(false)
    end

    it 'last flag wins for repeated validate flags' do
      opts = described_class.parse!(%w[--validate-types --no-validate-types lib])
      expect(opts[:validate_types]).to be(false)
    end

    it 'works with --rbs --validate-types together', :aggregate_failures do
      opts = described_class.parse!(%w[--rbs --validate-types lib])
      expect(opts[:validate_types]).to be(true)
      expect(opts[:rbs]).to be(true)
    end
  end
end
# rubocop:enable RSpec/MultipleDescribes, RSpec/ReceiveMessages

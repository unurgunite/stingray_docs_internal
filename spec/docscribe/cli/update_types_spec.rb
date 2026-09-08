# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'docscribe/cli'
require 'docscribe/cli/update_types'

DEFAULT_OPTS = Docscribe::CLI::Options::DEFAULT.dup

RSpec.describe Docscribe::CLI::UpdateTypes do
  describe 'helper methods' do
    describe '.parse_options' do
      it 'defaults dir to .' do
        opts = described_class.send(:parse_options, [])
        expect(opts[:dir]).to eq('.')
      end

      it 'accepts a directory argument' do
        Dir.mktmpdir do |dir|
          opts = described_class.send(:parse_options, [dir])
          expect(opts[:dir]).to eq(dir)
        end
      end
    end

    describe '.run_first_pass' do
      before do
        opts = DEFAULT_OPTS.merge(mode: :write, strategy: :aggressive, rbs_collection: true, no_boilerplate: true,
                                  keep_descriptions: true, rbs: true)
        allow(Docscribe::CLI::Options).to receive(:parse!).and_return(opts)
        allow(Docscribe::CLI::Run).to receive(:run)
        allow(File).to receive(:exist?).and_return(true)
      end

      it 'calls Options.parse! with aggressive flags' do
        described_class.send(:run_first_pass, 'lib')
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('-AkB'))
      end

      it 'calls Options.parse! with rbs-collection flag when collection exists' do
        described_class.send(:run_first_pass, 'lib')
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs-collection'))
      end

      it 'calls Options.parse! with --rbs when collection missing', :aggregate_failures do
        allow(File).to receive(:exist?).and_return(false)
        described_class.send(:run_first_pass, 'lib')
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs'))
        expect(Docscribe::CLI::Options).not_to have_received(:parse!).with(array_including('--rbs-collection'))
      end

      it 'calls Run.run with write mode and aggressive strategy' do
        described_class.send(:run_first_pass, 'lib')
        expect(Docscribe::CLI::Run).to have_received(:run).with(
          options: hash_including(mode: :write, strategy: :aggressive),
          argv: ['lib']
        )
      end
    end

    describe '.run_second_pass' do
      before do
        opts = DEFAULT_OPTS.merge(mode: :write, strategy: :safe, rbs_collection: true, no_boilerplate: true, rbs: true)
        allow(Docscribe::CLI::Options).to receive(:parse!).and_return(opts)
        allow(Docscribe::CLI::Run).to receive(:run)
        allow(File).to receive(:exist?).and_return(true)
      end

      it 'calls Options.parse! with safe flags' do
        described_class.send(:run_second_pass, 'lib')
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('-aB'))
      end

      it 'calls Options.parse! with rbs-collection flag when collection exists' do
        described_class.send(:run_second_pass, 'lib')
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs-collection'))
      end

      it 'calls Options.parse! with --rbs when collection missing', :aggregate_failures do
        allow(File).to receive(:exist?).and_return(false)
        described_class.send(:run_second_pass, 'lib')
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs'))
        expect(Docscribe::CLI::Options).not_to have_received(:parse!).with(array_including('--rbs-collection'))
      end

      it 'calls Run.run with write mode and safe strategy' do
        described_class.send(:run_second_pass, 'lib')
        expect(Docscribe::CLI::Run).to have_received(:run).with(
          options: hash_including(mode: :write, strategy: :safe),
          argv: ['lib']
        )
      end
    end

    describe 'file target first pass' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:file) do
        path = File.join(tmp_dir, 'foo.rb')
        FileUtils.touch(path)
        path
      end

      before do
        opts = DEFAULT_OPTS.merge(mode: :write, strategy: :aggressive, rbs_collection: true, no_boilerplate: true,
                                  keep_descriptions: true, rbs: true)
        allow(Docscribe::CLI::Options).to receive(:parse!).and_return(opts)
        allow(Docscribe::CLI::Run).to receive(:run)
        allow(File).to receive(:exist?).and_return(true)
        described_class.send(:run_first_pass, file)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'passes dirname to Options.parse!' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including(tmp_dir))
      end

      it 'passes file path to Run.run with aggressive strategy' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(options: hash_including(mode: :write, strategy: :aggressive), argv: [file])
      end
    end

    describe 'file target second pass' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:file) do
        path = File.join(tmp_dir, 'bar.rb')
        FileUtils.touch(path)
        path
      end
      let(:safe_opts) do
        DEFAULT_OPTS.merge(mode: :write, strategy: :safe, rbs_collection: true, no_boilerplate: true, rbs: true)
      end

      before do
        allow(Docscribe::CLI::Options).to receive(:parse!).and_return(safe_opts)
        allow(Docscribe::CLI::Run).to receive(:run)
        allow(File).to receive(:exist?).and_return(true)
        described_class.send(:run_second_pass, file)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'passes dirname to Options.parse!' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including(tmp_dir))
      end

      it 'passes file path to Run.run with safe strategy' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(options: hash_including(mode: :write, strategy: :safe), argv: [file])
      end
    end
  end

  describe 'file-scoped integration' do
    let!(:tmp_dir) { Dir.mktmpdir }
    let(:target_file) { File.join(tmp_dir, 'a.rb') }
    let(:other_file) { File.join(tmp_dir, 'b.rb') }

    before do
      File.write(target_file, "class A\ndef foo\n1\nend\nend\n")
      File.write(other_file, "class B\ndef bar\n2\nend\nend\n")
      described_class.run([target_file])
    end

    after { FileUtils.remove_entry(tmp_dir) }

    it 'updates target file' do
      expect(File.read(target_file)).to include('@return')
    end

    it 'does not update other file' do
      expect(File.read(other_file)).not_to include('@return')
    end
  end

  describe '.run' do
    it 'exits early if pass 1 fails' do
      allow(described_class).to receive(:run_first_pass).with('.').and_return(2)
      expect(described_class.run([])).to eq(2)
    end

    it 'does not run pass 2 when pass 1 fails' do
      allow(described_class).to receive(:run_first_pass).with('.').and_return(2)
      allow(described_class).to receive(:run_second_pass)
      described_class.run([])
      expect(described_class).not_to have_received(:run_second_pass)
    end

    it 'runs both passes and returns pass 2 exit code' do
      allow(described_class).to receive(:run_first_pass).with('.').and_return(0)
      allow(described_class).to receive(:run_second_pass).with('.').and_return(1)
      expect(described_class.run([])).to eq(1)
    end

    it 'returns 0 when both passes succeed' do
      allow(described_class).to receive(:run_first_pass).with('.').and_return(0)
      allow(described_class).to receive(:run_second_pass).with('.').and_return(0)
      expect(described_class.run([])).to eq(0)
    end
  end

  describe 'CLI integration' do
    subject(:result) { Open3.capture3('ruby', exe, 'update_types', *args) }

    let(:args) { [] }

    describe '--help' do
      let(:args) { ['--help'] }

      it 'shows usage' do
        expect(result[0]).to include('Usage:')
      end

      it 'exits 0' do
        expect(result[2].exitstatus).to eq(0)
      end
    end
  end
end

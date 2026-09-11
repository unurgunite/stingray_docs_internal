# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'docscribe/cli/update_types'

RSpec.describe Docscribe::CLI::UpdateTypes do
  describe '.parse_options target handling' do
    context 'when no arguments provided' do
      subject(:parsed_options) { described_class.send(:parse_options, []) }

      it 'defaults dir to .' do
        expect(parsed_options[:dir]).to eq('.')
      end
    end

    context 'when directory argument provided' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:parsed_options) { described_class.send(:parse_options, [tmp_dir]) }

      after { FileUtils.remove_entry(tmp_dir) }

      it 'accepts directory argument' do
        expect(parsed_options[:dir]).to eq(tmp_dir)
      end
    end

    context 'when file argument provided' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:target_file) do
        path = File.join(tmp_dir, 'a.rb')
        FileUtils.touch(path)
        path
      end
      let(:parsed_options) { described_class.send(:parse_options, [target_file]) }

      after { FileUtils.remove_entry(tmp_dir) }

      it 'accepts file argument as dir (target)' do
        expect(parsed_options[:dir]).to eq(target_file)
      end
    end

    context 'when --help flag provided' do
      let(:help_status) do
        described_class.send(:parse_options, ['--help'])
        0
      rescue SystemExit => e
        e.status
      end

      it 'raises SystemExit' do
        expect { described_class.send(:parse_options, ['--help']) }.to raise_error(SystemExit)
      end

      it 'exits with status 0' do
        expect(help_status).to eq(0)
      end
    end
  end

  describe '.run_first_pass RBS flag logic' do
    let(:default_options) { Docscribe::CLI::Options::DEFAULT.dup }
    let(:aggressive_options) do
      default_options.merge(mode: :write, strategy: :aggressive, rbs_collection: true, no_boilerplate: true, keep_descriptions: true, rbs: true)
    end

    before do
      allow(Docscribe::CLI::Options).to receive(:parse!).and_return(aggressive_options)
      allow(Docscribe::CLI::Run).to receive(:run).and_return(0)
    end

    context 'when dir has lock file' do
      let!(:tmp_dir) { Dir.mktmpdir }

      before do
        File.write(File.join(tmp_dir, 'rbs_collection.lock.yaml'), 'x')
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(File.join(tmp_dir, 'rbs_collection.lock.yaml')).and_return(true)
        allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(false)
        allow(File).to receive(:file?).and_return(false)
        described_class.send(:run_first_pass, tmp_dir)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'calls parse with --rbs-collection' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs-collection', tmp_dir))
      end

      it 'does not call parse with --rbs' do
        expect(Docscribe::CLI::Options).not_to have_received(:parse!).with(array_including('--rbs'))
      end
    end

    context 'when no lock file anywhere' do
      let!(:tmp_dir) { Dir.mktmpdir }

      before do
        allow(File).to receive_messages(exist?: false, file?: false)
        described_class.send(:run_first_pass, tmp_dir)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'calls parse with --rbs' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs', tmp_dir))
      end

      it 'does not call parse with --rbs-collection' do
        expect(Docscribe::CLI::Options).not_to have_received(:parse!).with(array_including('--rbs-collection'))
      end
    end

    context 'when root has lock even if dir lacks it' do
      let!(:tmp_dir) { Dir.mktmpdir }

      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(File.join(tmp_dir, 'rbs_collection.lock.yaml')).and_return(false)
        allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(true)
        allow(File).to receive(:file?).and_return(false)
        described_class.send(:run_first_pass, tmp_dir)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'uses --rbs-collection' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs-collection'))
      end
    end

    context 'when target is a file with collection lock' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:target_file) do
        path = File.join(tmp_dir, 'foo.rb')
        FileUtils.touch(path)
        path
      end

      before do
        File.write(File.join(tmp_dir, 'rbs_collection.lock.yaml'), 'x')
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with(target_file).and_return(true)
        allow(File).to receive(:file?).with(tmp_dir).and_return(false)
        allow(File).to receive(:exist?).with(File.join(tmp_dir, 'rbs_collection.lock.yaml')).and_return(true)
        allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(false)
        described_class.send(:run_first_pass, target_file)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'passes dirname to parse' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including(tmp_dir))
      end

      it 'does not pass file to parse' do
        expect(Docscribe::CLI::Options).not_to have_received(:parse!).with(array_including(target_file))
      end

      it 'passes file to Run' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(options: hash_including(strategy: :aggressive), argv: [target_file])
      end
    end

    context 'when file target without collection' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:target_file) do
        path = File.join(tmp_dir, 'foo.rb')
        FileUtils.touch(path)
        path
      end

      before do
        allow(File).to receive(:exist?).and_return(false)
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with(target_file).and_return(true)
        described_class.send(:run_first_pass, target_file)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'uses --rbs with dirname' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs', File.dirname(target_file)))
      end

      it 'passes file to Run' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(argv: [target_file], options: anything)
      end
    end

    context 'with aggressive strategy' do
      let!(:tmp_dir) { Dir.mktmpdir }

      before do
        allow(File).to receive_messages(exist?: false, file?: false)
        described_class.send(:run_first_pass, tmp_dir)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'passes aggressive strategy and write mode' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(options: hash_including(mode: :write, strategy: :aggressive), argv: [tmp_dir])
      end
    end
  end

  describe '.run_second_pass RBS flag logic' do
    let(:default_options) { Docscribe::CLI::Options::DEFAULT.dup }
    let(:safe_options) do
      default_options.merge(mode: :write, strategy: :safe, rbs_collection: true, no_boilerplate: true, rbs: true)
    end

    before do
      allow(Docscribe::CLI::Options).to receive(:parse!).and_return(safe_options)
      allow(Docscribe::CLI::Run).to receive(:run).and_return(0)
    end

    context 'when collection present' do
      let!(:tmp_dir) { Dir.mktmpdir }

      before do
        allow(File).to receive_messages(exist?: true, file?: false)
        described_class.send(:run_second_pass, tmp_dir)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'uses --rbs-collection' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs-collection', tmp_dir))
      end
    end

    context 'when missing collection' do
      let!(:tmp_dir) { Dir.mktmpdir }

      before do
        allow(File).to receive_messages(exist?: false, file?: false)
        described_class.send(:run_second_pass, tmp_dir)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'uses --rbs' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including('--rbs'))
      end

      it 'does not use --rbs-collection' do
        expect(Docscribe::CLI::Options).not_to have_received(:parse!).with(array_including('--rbs-collection'))
      end
    end

    context 'when file target with collection' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:target_file) do
        path = File.join(tmp_dir, 'bar.rb')
        FileUtils.touch(path)
        path
      end

      before do
        allow(File).to receive(:exist?).and_return(true)
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with(target_file).and_return(true)
        described_class.send(:run_second_pass, target_file)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'uses dirname for flag' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including(tmp_dir))
      end

      it 'passes file to Run with safe strategy' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(options: hash_including(strategy: :safe), argv: [target_file])
      end
    end

    context 'with safe strategy' do
      let!(:tmp_dir) { Dir.mktmpdir }

      before do
        allow(File).to receive_messages(exist?: false, file?: false)
        described_class.send(:run_second_pass, tmp_dir)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'passes safe strategy' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(options: hash_including(strategy: :safe, mode: :write), argv: [tmp_dir])
      end
    end
  end

  describe 'file vs dir integration' do
    let(:first_file_content) { "class A\ndef foo\n1\nend\nend\n" }
    let(:second_file_content) { "class B\ndef bar\n2\nend\nend\n" }

    context 'when given file path' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:first_file) { File.join(tmp_dir, 'a.rb') }
      let(:second_file) { File.join(tmp_dir, 'b.rb') }

      before do
        File.write(first_file, first_file_content)
        File.write(second_file, second_file_content)
        FileUtils.rm_f(File.join(tmp_dir, 'rbs_collection.lock.yaml'))
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(false)
        allow(File).to receive(:exist?).with(File.join(tmp_dir, 'rbs_collection.lock.yaml')).and_return(false)
        Dir.chdir(tmp_dir) { described_class.run([first_file]) }
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'updates target file' do
        expect(File.read(first_file)).to include('@return')
      end

      it 'does not update other file' do
        expect(File.read(second_file)).not_to include('@return')
      end
    end

    context 'when given directory' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:first_file) { File.join(tmp_dir, 'a.rb') }
      let(:second_file) { File.join(tmp_dir, 'b.rb') }

      before do
        File.write(first_file, first_file_content)
        File.write(second_file, second_file_content)
        described_class.run([tmp_dir])
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'updates first file' do
        expect(File.read(first_file)).to include('@return')
      end

      it 'updates second file' do
        expect(File.read(second_file)).to include('@return')
      end
    end

    context 'when file does not exist' do
      let(:aggressive_options) do
        Docscribe::CLI::Options::DEFAULT.dup.merge(mode: :write, strategy: :aggressive, rbs_collection: true, no_boilerplate: true, keep_descriptions: true, rbs: true)
      end
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:nonexistent_path) { File.join(tmp_dir, 'nonexistent.rb') }

      before do
        allow(File).to receive_messages(exist?: false, file?: false)
        allow(Docscribe::CLI::Options).to receive(:parse!).and_return(aggressive_options)
        allow(Docscribe::CLI::Run).to receive(:run).and_return(0)
        described_class.send(:run_first_pass, nonexistent_path)
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'passes nonexistent path to parse' do
        expect(Docscribe::CLI::Options).to have_received(:parse!).with(array_including(nonexistent_path))
      end

      it 'passes nonexistent path to Run' do
        expect(Docscribe::CLI::Run).to have_received(:run).with(argv: [nonexistent_path], options: anything)
      end
    end
  end

  describe '.run orchestration' do
    context 'when first pass fails' do
      let(:run_result) { described_class.run(['.']) }

      before do
        allow(described_class).to receive(:run_first_pass).and_return(2)
        allow(described_class).to receive(:run_second_pass)
      end

      it 'returns early exit code' do
        expect(run_result).to eq(2)
      end

      it 'does not run second pass' do
        run_result
        expect(described_class).not_to have_received(:run_second_pass)
      end
    end

    context 'when first succeeds and second returns 1' do
      let(:run_result) { described_class.run(['.']) }

      before do
        allow(described_class).to receive_messages(run_first_pass: 0, run_second_pass: 1)
      end

      it 'returns second pass exit code' do
        expect(run_result).to eq(1)
      end

      it 'runs second pass' do
        run_result
        expect(described_class).to have_received(:run_second_pass)
      end
    end

    context 'when both passes succeed' do
      before do
        allow(described_class).to receive_messages(run_first_pass: 0, run_second_pass: 0)
      end

      it 'returns 0' do
        expect(described_class.run([])).to eq(0)
      end
    end

    context 'when passing parsed target' do
      let!(:tmp_dir) { Dir.mktmpdir }
      let(:target_file) do
        path = File.join(tmp_dir, 'x.rb')
        FileUtils.touch(path)
        path
      end

      before do
        allow(described_class).to receive(:run_first_pass).with(target_file).and_return(0)
        allow(described_class).to receive(:run_second_pass).with(target_file).and_return(0)
        described_class.run([target_file])
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it 'passes target to first pass' do
        expect(described_class).to have_received(:run_first_pass).with(target_file)
      end

      it 'passes target to second pass' do
        expect(described_class).to have_received(:run_second_pass).with(target_file)
      end
    end
  end
end

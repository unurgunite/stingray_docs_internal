# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'docscribe/cli'
require 'docscribe/cli/check_for_comments'

RSpec.describe Docscribe::CLI::CheckForComments do
  describe '.resolve_placeholders' do
    it 'returns default_message and param_documentation from config' do
      config = resolve_config({ 'doc' => nil }, 'Param documentation.')
      expect(described_class.send(:resolve_placeholders,
                                  config)).to include('Method documentation.', 'Param documentation.')
    end

    it 'returns unique values only' do
      config = resolve_config({ 'doc' => { 'default_message' => 'Some text' } }, 'Some text')
      expect(described_class.send(:resolve_placeholders, config)).to eq(['Some text'])
    end

    it 'returns default when raw is nil' do
      config = resolve_config({ 'doc' => nil }, nil)
      expect(described_class.send(:resolve_placeholders, config)).to eq(['Method documentation.'])
    end
  end

  describe '.raw_or_default' do
    it 'falls back to DEFAULT when raw is nil' do
      config = resolve_config({ 'doc' => nil }, nil)
      expect(described_class.send(:raw_or_default, config, %w[doc default_message])).to eq('Method documentation.')
    end

    it 'returns raw value when present' do
      config = resolve_config({ 'doc' => { 'default_message' => 'Custom text' } }, nil)
      expect(described_class.send(:raw_or_default, config, %w[doc default_message])).to eq('Custom text')
    end
  end

  describe '.expand_paths' do
    it 'includes .rb files from directories' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/a.rb", '')
        File.write("#{dir}/b.rb", '')
        expect(described_class.send(:expand_paths, [dir]).size).to eq(2)
      end
    end

    it 'includes explicit .rb file paths' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/a.rb", '')
        expect(described_class.send(:expand_paths, ["#{dir}/a.rb"])).to eq(["#{dir}/a.rb"])
      end
    end
  end

  describe '.expand_single_path' do
    let(:files) { [] }

    it 'warns on missing paths' do
      expect { described_class.send(:expand_single_path, files, '/nonexistent') }
        .to output(/Skipping missing/).to_stderr
    end

    it 'warns on non-Ruby files' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/f.txt", '')
        expect { described_class.send(:expand_single_path, files, "#{dir}/f.txt") }
          .to output(/Skipping non-Ruby/).to_stderr
      end
    end
  end

  describe '.scan_file' do
    it 'finds placeholder in comment lines' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/test.rb", "# Method documentation.\ndef foo; end\n")
        result = described_class.send(:scan_file, "#{dir}/test.rb", ['Method documentation.'])
        expect(result).to eq(["#{dir}/test.rb", [[1, '# Method documentation.']]])
      end
    end

    it 'returns nil when no matches' do
      Dir.mktmpdir do |dir|
        path = "#{dir}/test.rb"
        File.write(path, "# Real doc\ndef foo; end\n")
        expect(described_class.send(:scan_file, path, ['Method documentation.'])).to be_nil
      end
    end

    it 'ignores non-comment lines' do
      Dir.mktmpdir do |dir|
        path = "#{dir}/test.rb"
        File.write(path, "x = 'Method documentation.'\n")
        expect(described_class.send(:scan_file, path, ['Method documentation.'])).to be_nil
      end
    end

    it 'ignores example comments with double #' do
      Dir.mktmpdir do |dir|
        path = "#{dir}/test.rb"
        File.write(path, "  #   # Method documentation.\ndef foo; end\n")
        expect(described_class.send(:scan_file, path, ['Method documentation.'])).to be_nil
      end
    end

    it 'matches multiple placeholders in one file' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/test.rb", "# Method documentation.\n# Param documentation.\ndef foo; end\n")
        result = described_class.send(:scan_file, "#{dir}/test.rb", ['Method documentation.', 'Param documentation.'])
        expect(result[1].size).to eq(2)
      end
    end
  end

  describe '.scan_paths' do
    it 'returns results for matching files' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/a.rb", "# Method documentation.\n")
        File.write("#{dir}/b.rb", "# Real doc\n")
        expect(described_class.send(:scan_paths, %W[#{dir}/a.rb #{dir}/b.rb], ['Method documentation.']).size).to eq(1)
      end
    end

    it 'returns matching file path' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/a.rb", "# Method documentation.\n")
        results = described_class.send(:scan_paths, ["#{dir}/a.rb"], ['Method documentation.'])
        expect(results[0][0]).to eq("#{dir}/a.rb")
      end
    end
  end

  describe '.no_placeholders_configured' do
    it 'returns 0' do
      expect(described_class.send(:no_placeholders_configured)).to eq(0)
    end

    it 'warns about missing placeholders' do
      expect { described_class.send(:no_placeholders_configured) }
        .to output(/No placeholder messages/).to_stderr
    end
  end

  describe '.run' do
    it 'returns 1 when no files found' do
      Dir.mktmpdir do |dir|
        expect(described_class.run([dir])).to eq(1)
      end
    end

    it 'returns 0 when no placeholders found' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/test.rb", "# Real documentation\ndef foo; end\n")
        expect(described_class.run([dir])).to eq(0)
      end
    end

    it 'returns 1 when placeholders found' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/test.rb", "# Method documentation.\ndef foo; end\n")
        expect(described_class.run([dir])).to eq(1)
      end
    end

    it 'reports placeholder count' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/test.rb", "# Method documentation.\ndef foo; end\n")
        expect(capture_stdout { described_class.run([dir]) }).to include('Found 1 placeholder(s)')
      end
    end

    it 'reports file path' do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/test.rb", "# Method documentation.\ndef foo; end\n")
        expect(capture_stdout { described_class.run([dir]) }).to include("#{dir}/test.rb")
      end
    end
  end

  describe 'CLI integration' do
    subject(:result) { Open3.capture3('ruby', exe, 'check_for_comments', *args) }

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

# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'docscribe/cli'

RSpec.describe Docscribe::CLI do
  describe '.dispatch_subcommand' do
    it 'maps every COMMANDS entry to a loadable file defining its constant' do
      described_class::COMMANDS.each do |cmd, const_name|
        file = described_class::SUBCOMMAND_FILES.fetch(cmd, cmd)
        expect { require "docscribe/cli/#{file}" }.not_to raise_error
        expect(described_class.const_get(const_name)).not_to be_nil
      end
    end

    it 'runs config --help without LoadError' do
      Dir.mktmpdir do |dir|
        _out, status = Open3.capture2('ruby', exe, 'config', '--help', chdir: dir)
        expect(status.exitstatus).to eq(0)
      end
    end
  end
end

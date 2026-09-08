# frozen_string_literal: true

require 'docscribe/cli'
require 'docscribe/cli/generate'
require 'tmpdir'
require 'fileutils'

RSpec.describe Docscribe::CLI::Generate do
  describe 'argument validation' do
    it 'returns 1 and warns when type is missing', :aggregate_failures do
      expect { expect(run).to eq(1) }.to output(/required/).to_stderr
    end

    it 'returns 1 and warns when class name is missing', :aggregate_failures do
      expect { expect(run('tag')).to eq(1) }.to output(/required/).to_stderr
    end

    it 'returns 1 for unknown plugin type', :aggregate_failures do
      expect { expect(run('unknown', 'MyPlugin')).to eq(1) }
        .to output(/unknown type/).to_stderr
    end

    it 'returns 1 for invalid constant name', :aggregate_failures do
      expect { expect(run('tag', 'not_valid')).to eq(1) }
        .to output(/not a valid Ruby constant/).to_stderr
    end
  end

  describe '--stdout' do
    it 'prints a TagPlugin skeleton to stdout', :aggregate_failures do
      expect { expect(run('tag', 'MyPlugin', '--stdout')).to eq(0) }
        .to output(/MyPlugin.*TagPlugin/m).to_stdout
    end

    it 'prints a CollectorPlugin skeleton to stdout', :aggregate_failures do
      expect { expect(run('collector', 'MyCollector', '--stdout')).to eq(0) }
        .to output(/MyCollector.*CollectorPlugin/m).to_stdout
    end

    it 'includes the class name in the tag template' do
      expect { run('tag', 'SincePlugin', '--stdout') }
        .to output(/class SincePlugin/).to_stdout
    end

    it 'includes the class name in the collector template' do
      expect { run('collector', 'AssocPlugin', '--stdout') }
        .to output(/class AssocPlugin/).to_stdout
    end
  end

  describe 'file generation' do
    let(:root) { Dir.mktmpdir }

    after { FileUtils.rm_rf(root) }

    describe 'TagPlugin' do
      let!(:status) { run('tag', 'SincePlugin', '--output', root) }

      it 'returns exit code 0' do
        expect(status).to eq(0)
      end

      it 'writes a file' do
        expect(File).to exist(File.join(root, 'since_plugin.rb'))
      end

      it 'includes the class name' do
        expect(File.read(File.join(root, 'since_plugin.rb'))).to include('class SincePlugin')
      end

      it 'includes the plugin type' do
        expect(File.read(File.join(root, 'since_plugin.rb'))).to include('TagPlugin')
      end
    end

    describe 'CollectorPlugin' do
      let!(:status) { run('collector', 'AssocPlugin', '--output', root) }

      it 'returns exit code 0' do
        expect(status).to eq(0)
      end

      it 'writes a file' do
        expect(File).to exist(File.join(root, 'assoc_plugin.rb'))
      end

      it 'includes the class name' do
        expect(File.read(File.join(root, 'assoc_plugin.rb'))).to include('class AssocPlugin')
      end

      it 'includes the plugin type' do
        expect(File.read(File.join(root, 'assoc_plugin.rb'))).to include('CollectorPlugin')
      end
    end

    it 'returns 1 and warns if the file already exists', :aggregate_failures do
      run('tag', 'SincePlugin', '--output', root)

      expect { expect(run('tag', 'SincePlugin', '--output', root)).to eq(1) }
        .to output(/already exists/).to_stderr
    end

    it 'creates the output directory if it does not exist' do
      nested = File.join(root, 'lib', 'plugins')
      run('tag', 'MyPlugin', '--output', nested)
      expect(File).to exist(File.join(nested, 'my_plugin.rb'))
    end
  end

  describe 'snake_case file naming' do
    let(:root) { Dir.mktmpdir }

    after { FileUtils.rm_rf(root) }

    it 'converts CamelCase to snake_case for the filename' do
      run('tag', 'ApiTagPlugin', '--output', root)
      expect(File).to exist(File.join(root, 'api_tag_plugin.rb'))
    end

    it 'handles single-word names' do
      run('collector', 'Associations', '--output', root)
      expect(File).to exist(File.join(root, 'associations.rb'))
    end
  end
end

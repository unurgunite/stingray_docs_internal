# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'docscribe/cli'
require 'docscribe/cli/sigs'

RSpec.describe Docscribe::CLI::Sigs do
  describe 'helper methods' do
    describe '.no_files_found' do
      it 'returns 2' do
        expect(described_class.send(:no_files_found)).to eq(2)
      end

      it 'warns' do
        expect { described_class.send(:no_files_found) }.to output(/No files found/).to_stderr
      end
    end

    describe '.format_method' do
      it 'formats instance methods with container' do
        result = described_class.send(:format_method, build_mdef(:instance, 'Foo'))
        expect(result).to eq('Foo#foo')
      end

      it 'formats class methods with container' do
        result = described_class.send(:format_method, build_mdef(:class, 'Foo'))
        expect(result).to eq('Foo#self.foo')
      end

      it 'formats methods without container' do
        result = described_class.send(:format_method, build_mdef(:instance, nil))
        expect(result).to eq('foo')
      end
    end

    describe '.container_name' do
      it 'returns nil for empty stack' do
        expect(described_class.send(:container_name, [])).to be_nil
      end

      it 'joins containers with ::' do
        expect(described_class.send(:container_name, %w[Foo Bar])).to eq('Foo::Bar')
      end
    end

    describe '.expand_single_path' do
      let(:files) { [] }

      it 'adds .rb files from directories' do
        Dir.mktmpdir do |dir|
          File.write("#{dir}/a.rb", '')
          described_class.send(:expand_single_path, files, dir)
          expect(files).to include("#{dir}/a.rb")
        end
      end

      it 'adds explicit file paths' do
        Dir.mktmpdir do |dir|
          File.write("#{dir}/a.rb", '')
          described_class.send(:expand_single_path, files, "#{dir}/a.rb")
          expect(files).to eq(["#{dir}/a.rb"])
        end
      end

      it 'warns on missing paths' do
        expect { described_class.send(:expand_single_path, files, '/nonexistent') }
          .to output(/Skipping missing/).to_stderr
      end
    end

    describe '.expand_paths' do
      it 'defaults to current dir' do
        Dir.mktmpdir { |tmp| expect(with_expand_empty(tmp)).to include(end_with('a.rb')) }
      end
    end

    describe '.extract_methods' do
      let(:tmpdir) { Dir.mktmpdir }

      after { FileUtils.remove_entry(tmpdir) }

      it 'extracts instance methods' do
        methods = extracted("class Foo\n  def bar; end\nend")
        expect(methods.map(&:name)).to eq([:bar])
      end

      it 'extracts class methods' do
        methods = extracted("class Foo\n  def self.bar; end\nend")
        expect(methods.map(&:name)).to eq([:bar])
      end

      it 'tracks nested modules and classes' do
        methods = extracted("module Foo\n  class Bar\n    def baz; end\n  end\nend")
        expect(methods.map(&:container)).to eq(['Foo::Bar'])
      end

      it 'handles singleton class syntax' do
        methods = extracted("class Foo\n  class << self\n    def bar; end\n  end\nend")
        expect(methods.map(&:name)).to eq([:bar])
      end

      it 'extracts methods from multiple files' do
        File.write("#{tmpdir}/a.rb", 'class A; def x; end; end')
        File.write("#{tmpdir}/b.rb", 'class B; def y; end; end')
        expect(described_class.send(:extract_methods,
                                    %W[#{tmpdir}/a.rb #{tmpdir}/b.rb]).map(&:name)).to contain_exactly(:x, :y)
      end

      it 'returns empty for files with only comments' do
        expect(extracted('# comment only')).to be_empty
      end

      it 'does not raise on syntax errors' do
        expect { extracted('class Foo; def bar') }.not_to raise_error
      end

      it 'returns empty for unparseable files' do
        expect(extracted('class Foo def bar end')).to be_empty
      end

      it 'returns empty for empty file content' do
        expect(extracted('')).to be_empty
      end
    end
  end

  describe 'CLI integration' do
    subject(:result) { Open3.capture3('ruby', exe, 'sigs', *args, chdir: dir) }

    let(:exe) { File.expand_path('exe/docscribe') }
    let(:dir) { Dir.mktmpdir }
    let(:args) { [] }

    after { FileUtils.remove_entry(dir) }

    describe '--help' do
      let(:args) { ['--help'] }

      it 'shows usage' do
        expect(result[0]).to include('Usage:')
      end

      it 'includes exit codes' do
        expect(result[0]).to include('Exit codes:')
      end

      it 'exits 0' do
        expect(result[2].exitstatus).to eq(0)
      end
    end

    describe 'without files' do
      it 'exits 2' do
        expect(result[2].exitstatus).to eq(2)
      end

      it 'warns about missing files' do
        expect(result[1]).to include('No files found')
      end
    end

    describe 'with files' do
      let(:args) { [file] }
      let(:file) { "#{dir}/test.rb" }

      before { File.write(file, 'class Foo; def bar; end; end') }

      it 'reports missing sigs when RBS available' do
        skip_unless_rbs_available!
        expect(result[2].exitstatus).to eq(1)
      end

      it 'outputs MISS lines' do
        skip_unless_rbs_available!
        expect(result[0]).to include('MISS')
      end

      it 'exits 2 when RBS gem unavailable' do
        skip 'RBS is available' if Gem::Specification.find_all_by_name('rbs').any?
        expect(result[2].exitstatus).to eq(2)
      end

      it 'warns about RBS gem when unavailable' do
        skip 'RBS is available' if Gem::Specification.find_all_by_name('rbs').any?
        expect(result[1]).to include('rbs gem is not installed')
      end
    end

    describe 'with --sig-dir option' do
      let(:args) { %W[--sig-dir #{sig_dir} #{file}] }
      let(:file) { "#{dir}/test.rb" }
      let(:sig_dir) { "#{dir}/mysig" }

      before do
        File.write(file, 'class Foo; def bar; end; end')
        FileUtils.mkdir_p(sig_dir)
      end

      it 'parses without error when RBS available' do
        skip_unless_rbs_available!
        expect(result[2].exitstatus).to eq(1)
      end

      it 'exits 2 when RBS gem unavailable' do
        skip 'RBS is available' if Gem::Specification.find_all_by_name('rbs').any?
        expect(result[2].exitstatus).to eq(2)
      end
    end
  end
end

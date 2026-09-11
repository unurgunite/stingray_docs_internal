# frozen_string_literal: true

module SigsHelper
  def build_mdef(scope, container)
    described_class::MethodDef.new(name: :foo, scope: scope, container: container, file: 'a.rb', line: 1)
  end

  def with_expand_empty(tmp)
    Dir.chdir(tmp) do
      File.write('a.rb', '')
      described_class.send(:expand_paths, [])
    end
  end

  def extracted(code)
    with_file(code) { |path| described_class.send(:extract_methods, [path]) }
  end

  def with_file(code)
    Dir.mktmpdir do |dir|
      path = "#{dir}/test.rb"
      File.write(path, code)
      yield path
    end
  end
end

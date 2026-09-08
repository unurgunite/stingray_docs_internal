# frozen_string_literal: true

require 'docscribe/cli/rbs_gen'

RSpec.describe Docscribe::CLI::RbsGen do
  describe 'Struct definitions with keyword_init' do
    let(:yard_tags) { described_class::YardTags.new(params: [], return_type: nil, options: []) }
    let(:param_tag) { described_class::ParamTag.new(name: 'foo', type: 'String') }
    let(:method_def_tags) { described_class::YardTags.new(params: [], return_type: 'String', options: []) }
    let(:method_def) do
      described_class::MethodDef.new(
        name: :bar,
        scope: :instance,
        container: 'MyClass',
        file: 'lib/foo.rb',
        line: 1,
        yard_tags: method_def_tags
      )
    end
    let(:walk_ctx) do
      described_class::WalkContext.new(
        containers: [],
        method_defs: [],
        path: 'lib/foo.rb',
        comment_map: {},
        src_lines: [],
        inside_sclass: false
      )
    end
    let(:build_tags) do
      described_class::YardTags.new(
        params: [described_class::ParamTag.new(name: 'foo', type: 'String')],
        return_type: 'String',
        options: []
      )
    end
    let(:build_method_def) do
      described_class::MethodDef.new(
        name: :foo,
        scope: :instance,
        container: 'MyClass',
        file: 'lib/foo.rb',
        line: 1,
        yard_tags: build_tags
      )
    end
    let(:build_result) { described_class.send(:build_param_strs, build_method_def) }

    it 'defines YardTags members' do
      expect(described_class::YardTags.members).to include(:params, :return_type, :options)
    end

    it 'defines YardTags as Struct with keyword_init' do
      expect(yard_tags.params).to eq([])
    end

    it 'defines ParamTag as Struct with keyword_init' do
      expect(param_tag.name).to eq('foo')
    end

    it 'defines MethodDef as Struct with keyword_init' do
      expect(method_def.name).to eq(:bar)
    end

    it 'defines WalkContext as Struct with keyword_init' do
      expect(walk_ctx.path).to eq('lib/foo.rb')
    end

    it 'build_param_strs returns Array<String> for MethodDef' do
      expect(build_result).to be_a(Array)
      expect(build_result).to all(be_a(String))
    end

    it 'build_param_strs includes param name' do
      expect(build_result.first).to include('foo')
    end
  end
end

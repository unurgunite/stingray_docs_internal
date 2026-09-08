# frozen_string_literal: true

RSpec.describe Docscribe::Plugin::Base::CollectorPlugin do
  subject(:out) { inline(code, config: conf, strategy: :safe) }

  after { Docscribe::Plugin::Registry.clear! }

  let(:conf) do
    Docscribe::Config.new(
      'emit' => {
        'header' => true,
        'param_tags' => true,
        'return_tag' => true,
        'include_default_message' => true
      }
    )
  end

  let(:code) do
    <<~RUBY
      class User
        def self.active(period: 30)
          where(created_at: period.days.ago..)
        end
      end
    RUBY
  end

  describe 'applies method_override without replacing the method pipeline (keeps @param)' do
    before do
      plugin = build_override_plugin(return_type: 'ActiveRecord::Relation')
      Docscribe::Plugin::Registry.register(plugin, priority: 10)
    end

    it { is_expected.to include('# +User.active+ -> ActiveRecord::Relation') }
    it { is_expected.to include('# Method documentation.') }
    it { is_expected.to include('# @param') }
    it { is_expected.to include(' period') }
    it { is_expected.to include('# @return [ActiveRecord::Relation]') }
  end

  describe 'picks the highest-priority method_override when multiple plugins target the same anchor' do
    before do
      low  = build_override_plugin(return_type: 'LOW')
      high = build_override_plugin(return_type: 'HIGH')
      Docscribe::Plugin::Registry.register(low, priority: 1)
      Docscribe::Plugin::Registry.register(high, priority: 2)
    end

    it { is_expected.to include('# +User.active+ -> HIGH') }
    it { is_expected.to include('# @return [HIGH]') }
    it { is_expected.not_to include('# @return [LOW]') }
    it { is_expected.to include('# @param') }
    it { is_expected.to include(' period') }
  end

  describe 'uses param_types from method_override in @param tags' do
    before do
      plugin = build_override_plugin(
        return_type: 'ActiveRecord::Relation',
        param_types: { 'period' => 'String' }
      )
      Docscribe::Plugin::Registry.register(plugin, priority: 10)
    end

    it { is_expected.to include('# @param [String] period') }
    it { is_expected.to include('# @return [ActiveRecord::Relation]') }
  end

  describe 'appends override tags to the doc block' do
    before do
      override_tag = Docscribe::Plugin::Tag.new(name: 'since', text: '2.0')
      plugin = build_override_plugin(
        return_type: 'ActiveRecord::Relation',
        tags: [override_tag]
      )
      Docscribe::Plugin::Registry.register(plugin, priority: 10)
    end

    it { is_expected.to include('# @since 2.0') }
  end

  describe 'accepts Hash-form tags in method_override and converts to Tag' do
    before do
      plugin = build_override_plugin(
        return_type: 'ActiveRecord::Relation',
        tags: [{ name: 'deprecated', text: 'Use .new instead' }]
      )
      Docscribe::Plugin::Registry.register(plugin, priority: 10)
    end

    it { is_expected.to include('# @deprecated Use .new instead') }
  end

  describe 'accepts string-keyed Hash-form tags' do
    before do
      plugin = build_override_plugin(
        return_type: 'ActiveRecord::Relation',
        tags: [{ 'name' => 'since', 'text' => '3.0' }]
      )
      Docscribe::Plugin::Registry.register(plugin, priority: 10)
    end

    it { is_expected.to include('# @since 3.0') }
  end
end

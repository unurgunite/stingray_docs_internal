# frozen_string_literal: true

require 'docscribe/cli/config_builder'
require 'docscribe/cli/options'

RSpec.describe Docscribe::CLI::ConfigBuilder do
  let(:default_options) { Docscribe::CLI::Options::DEFAULT }

  describe 'output_overrides?' do
    it 'returns false when neither flag is set' do
      expect(described_class.output_overrides?(default_options)).to be(false)
    end

    it 'returns true for keep_descriptions' do
      opts = default_options.merge(keep_descriptions: true)
      expect(described_class.output_overrides?(opts)).to be(true)
    end

    it 'returns true for no_boilerplate' do
      opts = default_options.merge(no_boilerplate: true)
      expect(described_class.output_overrides?(opts)).to be(true)
    end

    it 'returns true when both are set' do
      opts = default_options.merge(keep_descriptions: true, no_boilerplate: true)
      expect(described_class.output_overrides?(opts)).to be(true)
    end
  end

  describe 'apply_output_overrides' do
    let(:raw) { {} }

    it 'does nothing when neither flag is set' do
      described_class.apply_output_overrides(raw, default_options)
      expect(raw).to eq({})
    end

    context 'with no_boilerplate: true' do
      let(:options) { default_options.merge(no_boilerplate: true) }

      it 'sets include_default_message to false' do
        described_class.apply_output_overrides(raw, options)
        expect(raw['emit']['include_default_message']).to be(false)
      end

      it 'sets include_param_documentation to false' do
        described_class.apply_output_overrides(raw, options)
        expect(raw['emit']['include_param_documentation']).to be(false)
      end

      it 'creates emit hash when not present' do
        described_class.apply_output_overrides(raw, options)
        expect(raw['emit']).to be_a(Hash)
      end

      it 'preserves existing emit keys', :aggregate_failures do
        raw['emit'] = { 'some_other_key' => true }
        described_class.apply_output_overrides(raw, options)
        expect(raw['emit']['some_other_key']).to be(true)
        expect(raw['emit']['include_default_message']).to be(false)
      end
    end

    context 'with keep_descriptions: true' do
      it 'sets keep_descriptions in raw' do
        described_class.apply_output_overrides(raw, default_options.merge(keep_descriptions: true))
        expect(raw['keep_descriptions']).to be(true)
      end
    end

    context 'with both flags' do
      it 'sets all three values', :aggregate_failures do
        opts = default_options.merge(keep_descriptions: true, no_boilerplate: true)
        described_class.apply_output_overrides(raw, opts)
        expect(raw['keep_descriptions']).to be(true)
        expect(raw['emit']['include_default_message']).to be(false)
        expect(raw['emit']['include_param_documentation']).to be(false)
      end
    end
  end

  describe 'needs_override?' do
    it 'returns true when no_boilerplate is set' do
      opts = default_options.merge(no_boilerplate: true)
      expect(described_class.needs_override?(opts)).to be(true)
    end

    it 'returns true when keep_descriptions is set' do
      opts = default_options.merge(keep_descriptions: true)
      expect(described_class.needs_override?(opts)).to be(true)
    end

    it 'returns false when default options are passed' do
      expect(described_class.needs_override?(default_options)).to be(false)
    end
  end

  describe 'build' do
    let(:base) { Docscribe::Config.new(config_path: '/tmp/.docscribe/test.yml') }

    it 'preserves config_path from base without overrides' do
      config = described_class.build(base, default_options)
      expect(config.config_path).to eq('/tmp/.docscribe/test.yml')
    end

    it 'preserves config_path from base with overrides' do
      config = described_class.build(base, default_options.merge(no_boilerplate: true))
      expect(config.config_path).to eq('/tmp/.docscribe/test.yml')
    end

    it 'sets emit flags when no_boilerplate is in options', :aggregate_failures do
      config = described_class.build(base, default_options.merge(no_boilerplate: true))
      expect(config.raw['emit']['include_default_message']).to be(false)
      expect(config.raw['emit']['include_param_documentation']).to be(false)
    end

    it 'does not mutate the base config', :aggregate_failures do
      config = described_class.build(base, default_options.merge(no_boilerplate: true))
      expect(config.raw['emit']['include_default_message']).to be(false)
      expect(base.raw['emit']['include_default_message']).to be(true)
    end

    it 'handles keep_descriptions and no_boilerplate together', :aggregate_failures do
      opts = default_options.merge(keep_descriptions: true, no_boilerplate: true)
      config = described_class.build(base, opts)
      expect(config.raw['keep_descriptions']).to be(true)
      expect(config.raw['emit']['include_default_message']).to be(false)
      expect(config.raw['emit']['include_param_documentation']).to be(false)
    end
  end

  describe 'rbs_collection warning' do
    it 'warns when rbs_collection.lock.yaml is not found' do
      require 'docscribe/types/rbs/collection_loader'
      allow(Docscribe::Types::RBS::CollectionLoader).to receive(:resolve).and_return(nil)

      raw = Marshal.load(Marshal.dump(Docscribe::Config.new.raw))
      expect { described_class.apply_rbs_collection(raw) }
        .to output(/rbs_collection\.lock\.yaml not found/).to_stderr
    end

    context 'when config enables rbs.collection' do
      let(:conf) { Docscribe::Config.new('rbs' => { 'collection' => true }) }
      let(:options) { default_options }

      it 'skips the missing-collection nudge', :aggregate_failures do
        expect { described_class.warn_missing_rbs_collection(conf, options) }.not_to output.to_stderr
      end
    end
  end

  describe 'validation_overrides?' do
    it 'returns false when the flag was not passed (nil default)' do
      expect(described_class.validation_overrides?(default_options)).to be(false)
    end

    it 'returns true for explicit --validate-types' do
      opts = default_options.merge(validate_types: true)
      expect(described_class.validation_overrides?(opts)).to be(true)
    end

    it 'returns true for explicit --no-validate-types' do
      opts = default_options.merge(validate_types: false)
      expect(described_class.validation_overrides?(opts)).to be(true)
    end
  end

  describe 'apply_validation_overrides' do
    it 'sets true for --validate-types' do
      raw = {}
      described_class.apply_validation_overrides(raw, default_options.merge(validate_types: true))
      expect(raw['validate_types']).to be(true)
    end

    it 'sets false for --no-validate-types' do
      raw = { 'validate_types' => true }
      described_class.apply_validation_overrides(raw, default_options.merge(validate_types: false))
      expect(raw['validate_types']).to be(false)
    end
  end

  describe 'build with validate_types' do
    it 'keeps yml true when the flag was not passed', :aggregate_failures do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(false)
      base = Docscribe::Config.new('validate_types' => true)
      expect(described_class.build(base, default_options).validate_types?).to be(true)
    end

    it 'lets explicit false override yml true' do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(false)
      base = Docscribe::Config.new('validate_types' => true)
      opts = default_options.merge(validate_types: false)
      expect(described_class.build(base, opts).validate_types?).to be(false)
    end

    it 'lets explicit true enable validation without yml' do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(false)
      base = Docscribe::Config.new
      opts = default_options.merge(validate_types: true)
      expect(described_class.build(base, opts).validate_types?).to be(true)
    end
  end

  describe 'build without overrides warns about missing collection' do
    let(:base) { Docscribe::Config.new }

    it 'warns when the lock file exists' do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(true)
      expect { described_class.build(base, default_options) }
        .to output(/rbs_collection\.lock\.yaml found but --rbs-collection not set/).to_stderr
    end

    it 'returns the base config object' do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(true)
      expect(described_class.build(base, default_options)).to be(base)
    end

    it 'stays silent without the lock file' do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(false)
      expect { described_class.build(base, default_options) }.not_to output.to_stderr
    end

    it 'stays silent when suppression is configured' do
      base = Docscribe::Config.new('rbs' => { 'warn_missing_collection' => false })
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('rbs_collection.lock.yaml').and_return(true)
      expect { described_class.build(base, default_options) }.not_to output.to_stderr
    end
  end
end

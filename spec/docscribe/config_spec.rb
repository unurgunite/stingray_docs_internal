# frozen_string_literal: true

RSpec.describe Docscribe::Config do
  describe '#process_method?' do
    describe 'falls back to DEFAULT filter scopes/visibilities when filter keys are missing' do
      subject(:conf) { described_class.new }

      it { expect(conf.process_method?(container: 'A', scope: :instance, visibility: :public, name: :foo)).to be(true) }
      it { expect(conf.process_method?(container: 'A', scope: :class, visibility: :private, name: :bar)).to be(true) }
    end

    describe 'excludes matching methods even if included by scope/visibility' do
      subject(:conf) { described_class.new('filter' => { 'exclude' => ['*#initialize'] }) }

      it do
        expect(conf.process_method?(container: 'A', scope: :instance, visibility: :public,
                                    name: :initialize)).to be(false)
      end
    end

    describe 'when include is non-empty, only included methods pass' do
      subject(:conf) { described_class.new('filter' => { 'include' => ['A#foo'] }) }

      it { expect(conf.process_method?(container: 'A', scope: :instance, visibility: :public, name: :foo)).to be(true) }

      it do
        expect(conf.process_method?(container: 'A', scope: :instance, visibility: :public, name: :bar)).to be(false)
      end
    end

    describe 'respects visibilities allow-list' do
      subject(:conf) { described_class.new('filter' => { 'visibilities' => ['public'] }) }

      it { expect(conf.process_method?(container: 'A', scope: :instance, visibility: :public, name: :foo)).to be(true) }

      it do
        expect(conf.process_method?(container: 'A', scope: :instance, visibility: :private, name: :foo)).to be(false)
      end
    end
  end

  describe '#rbs_collection_dirs' do
    before do
      require 'docscribe/types/rbs/collection_loader'
    end

    context 'when explicit collection_dirs are configured' do
      subject(:dirs) { described_class.new('rbs' => { 'collection_dirs' => ['/tmp/coll'] }).send(:rbs_collection_dirs) }

      it 'uses them without auto-discovery' do
        allow(Docscribe::Types::RBS::CollectionLoader).to receive(:resolve).and_raise('must not resolve')
        expect(dirs).to eq(['/tmp/coll'])
      end
    end

    context 'when rbs.collection is true without explicit dirs' do
      subject(:dirs) { described_class.new('rbs' => { 'collection' => true }).send(:rbs_collection_dirs) }

      it 'auto-discovers from the lock file' do
        allow(Docscribe::Types::RBS::CollectionLoader).to receive(:resolve).and_return('/tmp/coll')
        expect(dirs).to eq(['/tmp/coll'])
      end

      it 'returns empty without noise when no lock file exists' do
        allow(Docscribe::Types::RBS::CollectionLoader).to receive(:resolve).and_return(nil)
        expect(dirs).to eq([])
      end
    end

    context 'when collection is not enabled' do
      subject(:dirs) { described_class.new.send(:rbs_collection_dirs) }

      it 'returns empty without auto-discovery' do
        allow(Docscribe::Types::RBS::CollectionLoader).to receive(:resolve).and_raise('must not resolve')
        expect(dirs).to eq([])
      end
    end
  end
end

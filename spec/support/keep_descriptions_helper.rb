# frozen_string_literal: true

module KeepDescriptionsHelper
  def idempotent_reinsert(out, rbs_content)
    Dir.mktmpdir do |dir|
      d = File.join(dir, 'sig')
      FileUtils.mkdir_p(d)
      File.write(File.join(d, 'demo.rbs'), rbs_content)

      c = Docscribe::Config.new('rbs' => { 'enabled' => true, 'sig_dirs' => [d] }, 'keep_descriptions' => true)
      described_class.insert_comments(out, strategy: :aggressive, config: c)
    end
  end
end

# frozen_string_literal: true

module CollectionLoaderHelper
  def write_lock(path: nil)
    data = { 'sources' => [], 'gems' => [] }
    data['path'] = path if path
    File.write(File.join(root, 'rbs_collection.lock.yaml'), data.to_yaml)
  end

  def create_collection_dir(rel)
    dir = File.join(root, rel)
    FileUtils.mkdir_p(dir)
    dir
  end
end

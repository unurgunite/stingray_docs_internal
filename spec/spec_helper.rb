# frozen_string_literal: true

require 'bundler/setup'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'docscribe'
Dir['./spec/support/*.rb'].sort.each { |file| require file }

RSpec.configure do |config|
  config.include HeaderRegex
  config.include InlineHelper
  config.include ParamTag
  config.include ExeHelper
  config.include RbsHelper
  config.include StreamHelper
  config.include SarifHelper
  config.include SuppressErrorHelper
  config.include CleanFileHelper
  config.include ServerWireHelper
  config.include DaemonHelper
  config.include DaemonSigHelper
  config.include DaemonRequestHelper
  config.include YardValidatorHelper
  config.include AstHelper
  config.include DaemonSourceHelper
  config.include FormatterHelper
  config.include PluginHelper
  config.include RbsTypeFormatterHelper
  config.include YardParserHelper
  config.include SigsHelper
  config.include RbsGenHelper
  config.include CheckForCommentsHelper
  config.include GenerateHelper
  config.include CollectionLoaderHelper
  config.include KeepDescriptionsHelper
  config.include NormalizeCommentHelper
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end

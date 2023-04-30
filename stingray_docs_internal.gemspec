# frozen_string_literal: true

require_relative "lib/stingray_docs_internal/version"

Gem::Specification.new do |spec|
  spec.name = "stingray_docs_internal"
  spec.version = StingrayDocsInternal::VERSION
  spec.authors = ["unurgunite"]
  spec.email = ["senpaiguru1488@gmail.com"]

  spec.summary = "This gem is used only for internal purposes in Stingray Technical LTD."
  spec.description = "Gem for generating internal documentation in Stingray Technical LTD."
  spec.homepage = "https://example.com"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://example.com"
  spec.metadata["changelog_uri"] = "https://example.com"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) || f.start_with?(*%w[bin/ test/ spec/ features/ .git .circleci appveyor])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end

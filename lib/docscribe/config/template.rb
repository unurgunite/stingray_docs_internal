# frozen_string_literal: true

module Docscribe
  # Default YAML config template for `docscribe init`.
  class Config
    # Return the default YAML template used by `docscribe init`.
    #
    # The template documents the most common CLI workflows and all supported
    # configuration sections with comments.
    #
    # @return [String]
    def self.default_yaml
      <<~YAML
        ---
        # Docscribe configuration file
        #
        # Docscribe works without this file — create it only for customization.
        #
        # Quick start:
        #   bundle exec docscribe lib          # check what would change
        #   bundle exec docscribe -a lib       # apply safe updates
        #   bundle exec docscribe -A lib       # rebuild all doc blocks
        #   bundle exec docscribe -AkB lib     # rebuild, keep descriptions, no boilerplate

        emit:
          # What to include in generated documentation
          header: false                       # +MyClass#foo+ -> ReturnType
          param_tags: true                    # @param tags
          return_tag: true                    # @return tag
          visibility_tags: true               # @private / @protected
          raise_tags: true                    # @raise tags
          rescue_conditional_returns: true    # @return [Type] if Error
          attributes: false                   # @!attribute for attr_*

          # Placeholder text for generated docs
          include_default_message: true       # "Method documentation."
          include_param_documentation: true   # "Param documentation."

        doc:
          # Default text and formatting
          default_message: "Method documentation."
          param_documentation: "Param documentation."
          param_tag_style: "type_name"        # "type_name" or "name_type"
          sort_tags: true
          tag_order: ["todo", "note", "api", "private", "protected", "param", "option", "yieldparam", "raise", "return"]

        inference:
          # Type inference behavior
          fallback_type: "Object"             # when uncertain
          nil_as_optional: true               # String | nil => String?
          treat_options_keyword_as_hash: true # options: keyword => Hash

        filter:
          # Which methods and files to process
          # Method format: "Container#method" (instance) or "Container.method" (class)
          # Supports globs ("*#initialize") and regex ("/^MyApp::.*$/")
          include: []
          exclude: []
          visibilities: ["public", "protected", "private"]
          scopes: ["instance", "class"]

          files:
            # File paths relative to project root (globs or /regex/)
            include: []
            exclude: ["spec"]

        methods:
          # Override defaults per scope and visibility.
          # Empty {} means "use values from `doc` section".
          #
          # Example:
          #   instance:
          #     public:
          #       default_message: "Public API."
          #     private:
          #       return_tag: false
          instance:
            public: {}
            protected: {}
            private: {}
          class:
            public: {}
            protected: {}
            private: {}

        rbs:
          # Use RBS signatures for better types (requires `gem "rbs"`)
          enabled: false
          sig_dirs: ["sig"]
          collection_dirs: []                 # auto-discovered from --rbs-collection
          collapse_generics: false            # Hash<Symbol, String> => Hash
          collapse_object_generics: false     # Hash<Object, Object> => Hash (keep if inner types are useful)
          collection: false                   # auto-discover from rbs_collection.lock.yaml
          warn_missing_collection: true       # warn if rbs_collection.lock.yaml exists without --rbs-collection

        sorbet:
          # Use Sorbet inline sigs and RBI files for better types
          enabled: false
          rbi_dirs: ["sorbet/rbi", "rbi"]
          collapse_generics: false
          collapse_object_generics: false

        # Preserve existing @param/@return descriptions in aggressive mode
        keep_descriptions: false

        # Skip @param for anonymous block arguments (&) (Ruby 3.2+)
        skip_anonymous_block_params: false

        # Validate YARD types against inferred/RBS types
        validate_types: false

        plugins:
          # Load custom plugins
          # Example:
          #   require:
          #     - ./docscribe_plugins
          #     - docscribe-rails-associations
          require: []
      YAML
    end
  end
end

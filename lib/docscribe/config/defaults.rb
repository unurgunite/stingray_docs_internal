# frozen_string_literal: true

module Docscribe
  class Config
    # Default configuration values used when no `docscribe.yml` is present or
    # when specific keys are missing from user config.
    #
    # These defaults define:
    # - which documentation tags are emitted
    # - default generated text
    # - type inference behavior
    # - method / file filtering
    # - optional RBS integration
    # - optional Sorbet integration
    DEFAULT = {
      'emit' => {
        'header' => false,
        'include_default_message' => true,
        'include_param_documentation' => true,
        'param_tags' => true,
        'return_tag' => true,
        'visibility_tags' => true,
        'raise_tags' => true,
        'rescue_conditional_returns' => true,
        'attributes' => false
      },
      'doc' => {
        'default_message' => 'Method documentation.',
        'param_tag_style' => 'type_name',
        'param_documentation' => 'Param documentation.',
        'sort_tags' => true,
        'tag_order' => %w[todo note api private protected param option yieldparam raise return]
      },
      'methods' => {
        'instance' => {
          'public' => {}, #: Hash[String, untyped]
          'protected' => {}, #: Hash[String, untyped]
          'private' => {} #: Hash[String, untyped]
        },
        'class' => {
          'public' => {}, #: Hash[String, untyped]
          'protected' => {}, #: Hash[String, untyped]
          'private' => {} #: Hash[String, untyped]
        }
      },
      'inference' => {
        'fallback_type' => 'Object',
        'nil_as_optional' => true,
        'treat_options_keyword_as_hash' => true
      },
      'filter' => {
        'visibilities' => %w[public protected private],
        'scopes' => %w[instance class],
        'include' => [], #: Array[String]
        'exclude' => [], #: Array[String]
        'files' => {
          'include' => [], #: Array[String]
          'exclude' => ['spec']
        }
      },
      'rbs' => {
        'enabled' => false,
        'collection' => false,
        'sig_dirs' => ['sig'],
        'collection_dirs' => [], #: Array[String]
        'collapse_generics' => false,
        'warn_missing_collection' => true,
        'collapse_object_generics' => false
      },
      'sorbet' => {
        'enabled' => false,
        'rbi_dirs' => ['sorbet/rbi', 'rbi'],
        'collapse_generics' => false,
        'collapse_object_generics' => false
      },
      'keep_descriptions' => false,
      'skip_anonymous_block_params' => false,
      'validate_types' => false,
      'plugins' => {
        'require' => [] #: Array[String]
      }
    }.freeze
  end
end

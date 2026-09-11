# frozen_string_literal: true

module Docscribe
  # Validation-related configuration.
  class Config
    # Whether to validate YARD types against inferred / external types.
    #
    # When enabled, `docscribe lib --validate-types` (or `validate_types: true`
    # in `docscribe.yml`) compares each `@param`/`@return` type written in YARD
    # against the type inferred from the method body or provided via RBS/Sorbet.
    # Mismatches are reported as `updated_param` / `updated_return` and, in
    # check mode, cause exit 1.
    #
    # @return [Boolean]
    def validate_types?
      fetch_bool(%w[validate_types], false)
    end
  end
end

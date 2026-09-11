# frozen_string_literal: true

target :lib do
  check 'lib'
  signature 'sig'
  collection_config 'rbs_collection.yaml'

  configure_code_diagnostics do |hash|
    # Accept these as non-blocking:
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = :information
    hash[Steep::Diagnostic::Ruby::BlockTypeMismatch] = :information
    hash[Steep::Diagnostic::Ruby::UnknownConstant] = :information
    hash[Steep::Diagnostic::Ruby::UnresolvedOverloading] = :information

    # Accept missing methods on `bot` type as warnings
    # (bot arises from prototype sigs with untyped params/hashes)
    hash[Steep::Diagnostic::Ruby::NoMethod] = :information

    # Accept keyword/hash splat limitations (opts.slice(...)**opts patterns)
    hash[Steep::Diagnostic::Ruby::InsufficientKeywordArguments] = :information
    hash[Steep::Diagnostic::Ruby::InsufficientPositionalArguments] = :information

    # Accept proto-sig type mismatches from simplistic rbs prototype rb output
    hash[Steep::Diagnostic::Ruby::ArgumentTypeMismatch] = :information
    hash[Steep::Diagnostic::Ruby::MethodBodyTypeMismatch] = :information
    hash[Steep::Diagnostic::Ruby::UnexpectedPositionalArgument] = :information
    hash[Steep::Diagnostic::Ruby::UnexpectedKeywordArgument] = :information
  end
end

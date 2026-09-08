# frozen_string_literal: true

require 'docscribe/types/yard/validator'
require 'docscribe/infer/constants'
require 'docscribe/validator/generic_compatibility'

module Docscribe
  module Validator
    # Compares YARD-documented types against inferred / external types.
    #
    # Lightweight, in-process checks only:
    # - last expression / literal inference (already in `Infer`)
    # - `core_rbs_provider` for stdlib sends (`String#to_i` etc.)
    # - `external_sig` (RBS/Sorbet) when available and `--validate-types` is on
    #
    # Heavy inter-procedural `send("foo")` graph is out of scope for this MVP.
    # When `expected` is `Object` (fallback) we silence to avoid false positives.
    class TypeMismatchValidator
      # @!attribute [rw] type
      #   @return [Symbol]
      #   @param [Symbol] value
      #
      # @!attribute [rw] yard_type
      #   @return [String?]
      #   @param [String?] value
      #
      # @!attribute [rw] expected_type
      #   @return [String?]
      #   @param [String?] value
      #
      # @!attribute [rw] message
      #   @return [String]
      #   @param [String] value
      #
      # @!attribute [rw] source
      #   @return [String?]
      #   @param [String?] value
      Result = Struct.new(:type, :yard_type, :expected_type, :message, :source, keyword_init: true)

      # @param [String] fallback_type value of `inference.fallback_type` (default `Object`)
      # @return [void]
      def initialize(fallback_type: Infer::FALLBACK_TYPE)
        @fallback_type = fallback_type.to_s
      end

      # Whether a documented param type mismatches the expected one.
      #
      # @param [String, nil] yard_type type from `@param [...]`
      # @param [String, nil] expected_type type from `external_sig` or `Infer`
      # @param [String, Symbol, nil] method_name method name for void compatibility
      # @return [Boolean]
      def mismatched_param?(yard_type, expected_type, method_name: nil)
        mismatched_return?(yard_type, expected_type, method_name: method_name)
      end

      # Whether a documented return type mismatches the expected one.
      #
      # @param [String, nil] yard_type type from `@return [...]`
      # @param [String, nil] expected_type inferred or external `normal_type`
      # @param [String, Symbol, nil] method_name method name for void compatibility
      # @return [Boolean]
      def mismatched_return?(yard_type, expected_type, method_name: nil)
        return false if blank_type?(yard_type)
        return false if blank_type?(expected_type)
        return false if expected_suppressed?(expected_type)
        return false if yard_compatible?(yard_type, expected_type, method_name: method_name)
        return false if types_normalized_equal?(yard_type, expected_type)

        !normalized_equal?(yard_type, expected_type)
      end

      # Whether YARD type is generic compatible with expected (e.g. Hash vs Hash<Symbol, String>).
      # Delegates to GenericCompatibility service for dynamic, map-dispatched checks.
      #
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @param [String, Symbol, nil] method_name method name for void compatibility threading
      # @return [Boolean]
      def generic_compatible?(yard_type, expected_type, method_name: nil)
        GenericCompatibility.compatible?(yard_type, expected_type, fallback_type: @fallback_type, method_name: method_name)
      end

      # Whether yard type is included in expected union.
      #
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @return [Boolean]
      def yard_in_expected_union?(yard_type, expected_type)
        return false if yard_type.nil? || expected_type.nil?

        normalized_yard = normalize(yard_type)
        expected_type.split(',').any? { |part| normalize(part) == normalized_yard }
      end

      # Whether void YARD type is compatible with fallback union or initialize/setup dynamic.
      #
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @param [String, Symbol, nil] method_name method name for dynamic check
      # @return [Boolean]
      def void_compatible?(yard_type, expected_type, method_name: nil)
        GenericCompatibility.void_compatible?(yard_type, expected_type, @fallback_type, method_name: method_name)
      end

      # Whether a type string is a union of only fallback types (with optional `?`).
      #
      # @param [String, nil] type_str
      # @return [Boolean]
      def fallback_union?(type_str)
        return false if type_str.nil? || type_str.strip.empty?

        fallback_norm = normalize(@fallback_type)
        parts = type_str.to_s.split(',').map { |p| normalize(p.strip.delete_suffix('?').strip) }
        parts.all? { |p| p == fallback_norm || p.empty? }
      end

      # Whether a YARD type string has invalid syntax (e.g. `Sym bol` leftover).
      #
      # @param [String, nil] yard_type
      # @return [Boolean]
      def invalid_syntax?(yard_type) # rubocop:disable SortedMethodsByCall/Waterfall
        return false if yard_type.nil? || yard_type.strip.empty?

        !Types::Yard::Validator.valid?(yard_type)
      end

      # Build a Result for a return mismatch, or nil if no mismatch.
      #
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @param [String] source source of expected type: "rbs" or "infer"
      # @param [String, Symbol, nil] method_name method name for void compatibility
      # @return [Docscribe::Validator::TypeMismatchValidator::Result, nil]
      def check_return(yard_type, expected_type, source: 'infer', method_name: nil)
        return invalid_return_result(yard_type, expected_type) if invalid_syntax?(yard_type)
        return unless mismatched_return?(yard_type, expected_type, method_name: method_name)

        mismatch_return_result(yard_type, expected_type, source: source)
      end

      # Build a Result for a param mismatch, or nil if no mismatch.
      #
      # @param [String] param_name
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @param [String] source source of expected type: "rbs" or "infer"
      # @param [String, Symbol, nil] method_name method name for void compatibility
      # @return [Docscribe::Validator::TypeMismatchValidator::Result, nil]
      def check_param(param_name, yard_type, expected_type, source: 'infer', method_name: nil)
        return invalid_param_result(param_name, yard_type, expected_type) if invalid_syntax?(yard_type)
        return unless mismatched_param?(yard_type, expected_type, method_name: method_name)

        mismatch_param_result(param_name, yard_type, expected_type, source: source)
      end

      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @return [Docscribe::Validator::TypeMismatchValidator::Result]
      def invalid_return_result(yard_type, expected_type)
        Result.new(
          type: :invalid_syntax,
          yard_type: yard_type,
          expected_type: expected_type,
          message: "invalid YARD type [#{yard_type}]#{" expected [#{expected_type}]" if expected_type && expected_type != @fallback_type}",
          source: 'syntax'
        )
      end

      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @param [String] source
      # @return [Docscribe::Validator::TypeMismatchValidator::Result]
      def mismatch_return_result(yard_type, expected_type, source: 'infer')
        Result.new(
          type: :type_mismatch_return,
          yard_type: yard_type,
          expected_type: expected_type,
          message: "updated @return from #{yard_type} to #{expected_type}",
          source: source
        )
      end

      # @param [String] param_name
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @return [Docscribe::Validator::TypeMismatchValidator::Result]
      def invalid_param_result(param_name, yard_type, expected_type)
        Result.new(
          type: :invalid_syntax,
          yard_type: yard_type,
          expected_type: expected_type,
          message: "invalid YARD type [#{yard_type}] for @param #{param_name}#{" expected [#{expected_type}]" if expected_type && expected_type != @fallback_type}",
          source: 'syntax'
        )
      end

      # @param [String] param_name
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @param [String] source
      # @return [Docscribe::Validator::TypeMismatchValidator::Result]
      def mismatch_param_result(param_name, yard_type, expected_type, source: 'infer')
        Result.new(
          type: :type_mismatch_param,
          yard_type: yard_type,
          expected_type: expected_type,
          message: "updated @param #{param_name} from #{yard_type} to #{expected_type}",
          source: source
        )
      end

      private

      # Whether type string blank (nil or whitespace).
      #
      # @private
      # @param [String, nil] type_str
      # @return [Boolean]
      def blank_type?(type_str)
        type_str.nil? || type_str.strip.empty?
      end

      # Whether expected suppressed as fallback (uncertain).
      #
      # @private
      # @param [String, nil] expected_type
      # @return [Boolean]
      def expected_suppressed?(expected_type)
        normalize(expected_type) == @fallback_type || fallback_union?(expected_type)
      end

      # Whether yard compatible with expected via void/union/generic.
      #
      # @private
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @param [String, Symbol, nil] method_name method name for void compatibility
      # @return [Boolean]
      def yard_compatible?(yard_type, expected_type, method_name: nil)
        void_compatible?(yard_type, expected_type, method_name: method_name) ||
          yard_in_expected_union?(yard_type, expected_type) ||
          generic_compatible?(yard_type, expected_type, method_name: method_name)
      end

      # Whether types equal after normalization (including optional "?").
      #
      # @private
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @return [Boolean]
      def types_normalized_equal?(yard_type, expected_type)
        normalized_equal?(yard_type, expected_type) || optional_normalized_equal?(yard_type, expected_type)
      end

      # Whether normalized types equal.
      #
      # @private
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @return [Boolean]
      def normalized_equal?(yard_type, expected_type)
        normalize(yard_type) == normalize(expected_type)
      end

      # Whether optional-normalized types equal.
      #
      # @private
      # @param [String, nil] yard_type
      # @param [String, nil] expected_type
      # @return [Boolean]
      def optional_normalized_equal?(yard_type, expected_type)
        normalize(yard_type).delete_suffix('?') == normalize(expected_type).delete_suffix('?')
      end

      # Normalize a type string for comparison (strip, squeeze spaces, unify RBS/YARD syntax).
      #
      # @private
      # @param [String, nil] type_str
      # @return [String]
      def normalize(type_str)
        s = type_str.to_s
        s = s.sub(/#.*\z/m, '').strip unless s.lstrip.start_with?('#')
        s.strip.squeeze(' ').gsub('[', '<').gsub(']', '>').gsub(/\buntyped\b/, 'Object').gsub(/\bFALLBACK_TYPE\b/, 'Object')
      end
    end
  end
end

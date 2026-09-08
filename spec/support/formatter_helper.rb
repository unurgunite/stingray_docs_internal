# frozen_string_literal: true

module FormatterHelper
  # Convenience wrappers used in source_propagation_spec.
  #
  # @param [String] source source identifier
  # @return [Hash]
  def json_offense_for(source)
    build_json_state_with_source(source)
  end

  # Build JSON state with source and parse offense.
  #
  # @param [String] source source identifier
  # @return [Hash]
  def build_json_state_with_source(source)
    state = base_state(source)
    options = { verbose: false, quiet: false, explain: false, mode: :check }
    parsed = JSON.parse(capture_stdout { formatter_json.format_check_summary(state: state, options: options) })
    parsed['files'][0]['offenses'][0]
  end

  # @param [String] source source identifier
  # @return [Hash]
  def sarif_result_for(source)
    build_sarif_state_with_source(source)
  end

  # Build SARIF state with source and parse result.
  #
  # @param [String] source source identifier
  # @return [Hash]
  def build_sarif_state_with_source(source)
    state = base_state(source)
    options = { verbose: false, quiet: false, explain: false, mode: :check, format: :sarif }
    parsed = JSON.parse(capture_stdout { formatter_sarif.format_check_summary(state: state, options: options) })
    parsed['runs'][0]['results'][0]
  end

  # Build a base state with a single fail change containing source.
  #
  # @param [String] source source identifier
  # @return [Hash]
  def base_state(source)
    {
      changed: false, had_errors: false, checked_ok: 0, checked_fail: 1,
      corrected: 0, corrected_paths: [], corrected_changes: {},
      fail_paths: ['test.rb'],
      fail_changes: { 'test.rb' => [{ type: :updated_return, line: 5, method: 'Foo#bar', source: source, message: 'msg' }] },
      error_paths: [], error_messages: {},
      type_mismatch_paths: [], type_mismatch_changes: {}
    }
  end
end

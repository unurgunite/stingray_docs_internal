# frozen_string_literal: true

require 'yaml'
require 'pathname'
require 'psych'

module Docscribe
  # Application configuration with deep-merge defaults and overrides.
  class Config
    # @!attribute [r] raw
    #   @return [Hash<String, Object>]
    attr_reader :raw

    # @!attribute [r] config_path
    #   @return [String?]
    attr_reader :config_path

    # Create a configuration object from a raw config hash.
    #
    # Missing keys are filled from {DEFAULT} via deep merge.
    #
    # @param [String?] config_path optional path to the config file
    # @param [Hash<String, Object>] raw user-provided config hash
    # @return [void]
    def initialize(config_path: nil, **raw)
      @raw = deep_merge(DEFAULT, raw)
      @config_path = config_path
    end

    # @return [Object]
    def to_h
      hash = {} #: Hash[String, Object]
      instance_variables.each do |var|
        key = var.to_s.sub('@', '')
        hash[key] = instance_variable_get(var)
      end
      hash
    end
  end
end

require_relative 'config/defaults'
require_relative 'config/utils'
require_relative 'config/loader'
require_relative 'config/template'
require_relative 'config/emit'
require_relative 'config/filtering'
require_relative 'config/rbs'
require_relative 'config/sorting'
require_relative 'config/sorbet'
require_relative 'config/plugin'
require_relative 'config/validation'

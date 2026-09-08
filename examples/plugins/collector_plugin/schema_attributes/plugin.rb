# frozen_string_literal: true

require 'docscribe/plugin'
require 'docscribe/infer/ast_walk'

module DocscribePlugins
  # Generates YARD documentation for ActiveRecord database columns.
  #
  # Reads `db/schema.rb` and for each table found, generates `@!attribute`
  # doc blocks for models that map to that table.
  #
  # Supports:
  # - boolean, integer, bigint, float, decimal
  # - string, text, binary, uuid, citext
  # - datetime, date, time, timestamp
  # - json, jsonb, inet, hstore, enum
  #
  # Skips:
  # - id (primary key)
  # - created_at, updated_at, deleted_at (standard Rails timestamps)
  #
  # @example Registration
  #   require 'examples/plugins/collector_plugin/schema_attributes/plugin'
  #   Docscribe::Plugin::Registry.register(DocscribePlugins::SchemaAttributes.new)
  #
  # @example Generated doc block
  #   # @!attribute [r] email
  #   #   @return [String]
  #   #
  #   #   @!attribute [r] is_admin
  #   #   @return [Boolean]
  #   class User < ApplicationRecord
  #   end
  class SchemaAttributes < Docscribe::Plugin::Base::CollectorPlugin
    # @!attribute [r] root
    #   @return [String] Rails application root directory
    attr_reader :root

    # Create a new schema attribute collector.
    #
    # @param [String] root
    # @return [self]
    def initialize(root: Dir.pwd)
      super()
      @root = root
      @schema = nil
    end

    # Column types from schema.rb mapped to YARD types.
    #
    # @private
    # @return [Hash{String => String}]
    COLUMN_TYPE_MAP = {
      'boolean' => 'Boolean',
      'integer' => 'Integer',
      'bigint' => 'Integer',
      'float' => 'Float',
      'decimal' => 'BigDecimal',
      'string' => 'String',
      'text' => 'String',
      'binary' => 'String',
      'datetime' => 'Time',
      'date' => 'Date',
      'time' => 'Time',
      'timestamp' => 'Time',
      'json' => 'Hash',
      'jsonb' => 'Hash',
      'inet' => 'IPAddr',
      'uuid' => 'String',
      'citext' => 'String',
      'hstore' => 'Hash',
      'enum' => 'String'
    }.freeze

    # Standard Rails columns that are documented by convention and skipped.
    #
    # @private
    # @return [Set<String>]
    SKIPPED_COLUMNS = %w[id created_at updated_at deleted_at].to_set.freeze

    # Column types that are recognized in schema.rb.
    #
    # @private
    # @return [Array<Symbol>]
    RECOGNIZED_COLUMNS = COLUMN_TYPE_MAP.keys.map(&:to_sym).freeze

    # Walk the AST and return doc insertion targets for database columns.
    #
    # @param [Parser::AST::Node] ast
    # @param [Parser::Source::Buffer] _buffer
    # @return [Array<Hash>]
    def collect(ast, _buffer)
      return [] unless active_record_model?(ast)

      load_schema!
      return [] if @schema.empty?

      model_name = extract_model_name(ast)
      return [] unless model_name

      table_name = model_name_to_table_name(model_name)
      columns = @schema[table_name]
      return [] unless columns

      build_attribute_docs(ast, table_name, columns)
    end

    private

    # Whether the AST defines an ActiveRecord model class.
    #
    # @private
    # @param [Parser::AST::Node] ast
    # @return [Boolean]
    def active_record_model?(ast)
      Docscribe::Infer::ASTWalk.walk(ast) do |node|
        next unless node.type == :class

        _name, parent = *node
        next unless parent

        return true if active_record_parent?(parent)
      end

      false
    end

    # @private
    # @param [Object] parent
    # @return [Object]
    def active_record_parent?(parent)
      application_record_parent?(parent) || active_record_base_parent?(parent)
    end

    # @private
    # @param [Object] parent
    # @return [Object]
    def application_record_parent?(parent)
      parent.type == :const && parent.children[1] == :ApplicationRecord
    end

    # @private
    # @param [Object] parent
    # @return [Object]
    def active_record_base_parent?(parent)
      parent.type == :const &&
        parent.children[0]&.type == :const &&
        parent.children[0].children[1] == :ActiveRecord &&
        parent.children[1] == :Base
    end

    # Load schema.rb from the project root and parse it.
    #
    # @private
    # @raise [StandardError]
    # @return [void]
    def load_schema!
      return if @schema

      path = File.join(@root, 'db', 'schema.rb')
      return @schema = {} unless File.file?(path)

      source = File.read(path)
      @schema = parse_schema(source)
    rescue StandardError => e
      warn "Docscribe SchemaAttributes: failed to parse schema.rb: #{e.message}" if ENV['DOCSCRIBE_DEBUG'] == '1'
      @schema = {}
    end

    # Extract the model class name from the AST.
    #
    # @private
    # @param [Parser::AST::Node] ast
    # @return [String, nil]
    def extract_model_name(ast)
      Docscribe::Infer::ASTWalk.walk(ast) do |node|
        if node.type == :class
          name_node = node.children[0]
          return resolve_const_name(name_node) if name_node
        end
      end
      nil
    end

    # Resolve a possibly-namespaced constant name to a string.
    #
    # @private
    # @param [Parser::AST::Node] node
    # @return [String, nil]
    def resolve_const_name(node)
      return nil unless node && node.type == :const

      name = node.children[1]&.to_s
      return name if node.children[0].nil?

      prefix = resolve_const_name(node.children[0])
      return name unless prefix

      "#{prefix}::#{name}"
    end

    # Convert a model class name to a table name.
    #
    # @private
    # @param [String] model_name
    # @return [String]
    def model_name_to_table_name(model_name)
      parts = model_name.split('::')
      table = parts.map do |p|
        p.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
         .downcase
      end.join('_')
      pluralize(table)
    end

    # Simple English pluralization (handles most common cases).
    #
    # @private
    # @param [String] word
    # @return [String]
    def pluralize(word)
      return word if word.end_with?('s', 'x', 'z', 'ch', 'sh')
      return "#{word[0..-2]}ies" if word.match?(/[^aeiou]y\Z/)
      return "#{word}es" if word.end_with?('es', 'us') || word.match?(/[^aeiou]o\Z/)
      return "#{word[0..-3]}ves" if word.end_with?('fe')
      return "#{word[0..-2]}ves" if word.end_with?('f')

      "#{word}s"
    end

    # Parse schema.rb source into a hash of table_name => columns.
    #
    # @private
    # @param [String] source
    # @return [Hash{String => Array<Hash>}]
    def parse_schema(source)
      tables = {}
      current_table = nil

      source.each_line do |line|
        current_table = parse_table_line(line, tables, current_table)
      end

      tables
    end

    # @private
    # @param [Object] line
    # @param [Object] tables
    # @param [Object] current_table
    # @return [Object]
    def parse_table_line(line, tables, current_table)
      case line
      when /\A\s*create_table\s+["'](\w+)["']/
        new_table_in_schema(line, tables)
      when /\A\s*t\.(\w+)\s+["'](\w+)["']/
        add_column_from_line(line, tables, current_table)
        current_table
      when /\A\s*end\s*\Z/ then nil
      else current_table
      end
    end

    # @private
    # @param [Object] _line
    # @param [Object] tables
    # @return [Object]
    def new_table_in_schema(_line, tables)
      table_name = ::Regexp.last_match(1)
      tables[table_name] ||= []
      table_name
    end

    # @private
    # @param [Object] tables
    # @param [Object] current_table
    # @return [Object]
    def add_column_from_line(tables, current_table)
      col_type = ::Regexp.last_match(1)
      col_name = ::Regexp.last_match(2)

      return unless recognized_column?(col_type, col_name)

      tables[current_table] << {
        name: col_name,
        type: col_type
      }
    end

    # @private
    # @param [Object] col_type
    # @param [Object] col_name
    # @return [Object]
    def recognized_column?(col_type, col_name)
      RECOGNIZED_COLUMNS.include?(col_type.to_sym) && !SKIPPED_COLUMNS.include?(col_name)
    end

    # Build @!attribute doc blocks for all columns of a table.
    #
    # @private
    # @param [Parser::AST::Node] ast
    # @param [String] _table_name
    # @param [Array<Hash>] columns
    # @return [Array<Hash>]
    def build_attribute_docs(ast, _table_name, columns)
      results = []

      Docscribe::Infer::ASTWalk.walk(ast) do |node|
        collect_class_attributes(node, columns, results)
      end

      results
    end

    # @private
    # @param [Object] node
    # @param [Object] columns
    # @param [Object] results
    # @return [Object]
    def collect_class_attributes(node, columns, results)
      return unless node.type == :class

      indent = attribute_indent(node)

      columns.each do |column|
        doc = build_attribute_doc(column, indent, node)
        results << doc if doc
      end
    end

    # @private
    # @param [Object] node
    # @return [Object]
    def attribute_indent(node)
      _name, _parent, body = *node

      return '' unless body

      stmts = body.type == :begin ? body.children : [body]
      extract_indent(stmts.first || node)
    end

    # @private
    # @param [Object] column
    # @param [Object] indent
    # @param [Object] node
    # @return [Hash]
    def build_attribute_doc(column, indent, node)
      return if SKIPPED_COLUMNS.include?(column[:name])

      yard_type = COLUMN_TYPE_MAP[column[:type]] || 'Object'

      {
        anchor_node: node,
        doc: build_doc(column[:name], yard_type, indent)
      }
    end

    # Build a single @!attribute doc block for one column.
    #
    # @private
    # @param [String] column_name
    # @param [String] yard_type
    # @param [String] indent
    # @return [String]
    def build_doc(column_name, yard_type, indent)
      lines = []
      lines << "#{indent}# @!attribute [r] #{column_name}"
      lines << "#{indent}#   @return [#{yard_type}]"
      lines << "#{indent}#"
      lines.map { |l| "#{l}\n" }.join
    end

    # Extract source indentation from a node.
    #
    # @private
    # @param [Parser::AST::Node] node
    # @raise [StandardError]
    # @return [String]
    def extract_indent(node)
      line = node.loc.expression.source_line
      line[/\A[ \t]*/] || ''
    rescue StandardError
      '  '
    end
  end
end

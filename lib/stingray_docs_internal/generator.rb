# frozen_string_literal: true

module StingrayDocsInternal
  module Generator
    class << self
      def generate_documentation(code)
        YARD.parse_string(code)

        YARD::Registry.all(:method).map do |method_obj|
          visibility = method_obj.visibility
          next if visibility == :protected

          generate_method_doc(method_obj)
        end.join("\n")
      end

      private

      def generate_method_doc(method_obj)
        params = generate_params(method_obj)
        symbol = method_obj.scope == :instance ? "#" : "."
        type = "Object" # You can customize this based on your code analysis
        private = method_obj.private? ? "# @private\n" : ""
        output_documentation(method_class: method_obj.parent.path, method_symbol: symbol, method_name: method_obj.name,
                             generated_params: params, private_tag: private, source: method_obj.source.lines.join,
                             return_type: type)
      end

      def generate_params(method_obj)
        method_obj.parameters.map do |param_name, default|
          param_type = "Object" # You can customize this based on your code analysis
          option = default.nil? ? "param" : "option"
          "# @#{option} [#{param_type}] #{param_name} #{option} documentation."
        end.join("\n")
      end

      def output_documentation(**options)
        <<~DOC
          # #{options[:method_class]}#{options[:method_symbol]}#{options[:method_name]} -> #{options[:return_type]}
          #
          # Method documentation.
          #
          #{options[:private_tag]}#{options[:generated_params]}
          # @return [#{options[:return_type]}]
          #{options[:source]}
        DOC
      end
    end
  end
end

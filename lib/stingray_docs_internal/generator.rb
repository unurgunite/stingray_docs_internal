# frozen_string_literal: true

module StingrayDocsInternal # :nodoc:
  module Generator # :nodoc:
    class << self
      # +Generator.generate_documentation+            -> Object
      #
      # Documentation generator.
      #
      # @param [String] code The source code to generate documentation for.
      # @return [String] The generated documentation.
      def generate_documentation(code)
        private_methods_list = MethodAnalyzer.private_methods_list(code)
        YARD.parse_string(code)
        YARD::Registry.all(:class, :module).map do |method_obj|
          class_name = method_obj.name
          methods = public_interface(method_obj, class_name).join("\n")

          private_methods = private_interface(method_obj, class_name, private_methods_list)
          private_methods_block = private_methods.empty? ? "" : " private\n  #{private_methods.join("\n")}"

          docstring(method_obj.type, class_name, methods, private_methods_block)
        end.join("\n")
      end

      private

      # +Generator.public_interface+                  -> Array
      #
      # Generates documentation for public methods.
      #
      # @private
      # @param [Symbol] class_obj The class or module object.
      # @param [Symbol] class_name The name of the class or module.
      # @return [Array] An array of documentation strings for public methods.
      def public_interface(class_obj, class_name)
        class_obj.meths(inherited: false).map do |method_obj|
          next if method_obj.visibility != :public

          docs_helper(class_name, method_obj)
        end
      end

      # +Generator.private_interface+                 -> Array
      #
      # Generates documentation for private methods.
      #
      # @private
      # @param [Symbol] class_obj The class or module object.
      # @param [Symbol] class_name The name of the class or module.
      # @param [Array] private_methods_list The list of private methods.
      # @return [Array] An array of documentation strings for private methods.
      def private_interface(class_obj, class_name, private_methods_list)
        class_obj.meths(inherited: false).select { _1.visibility == :private }.map do |method_obj|
          next docs_helper(class_name, method_obj, private: false) unless private_methods_list.include? method_obj.name

          docs_helper(class_name, method_obj, private: true)
        end
      end

      # +Generator.docs_helper+                       -> String
      #
      # Generates documentation for a single method.
      #
      # @private
      # @param [Symbol] class_name The name of the class or module.
      # @param [YARD::CodeObjects::MethodObject] method_obj The method object.
      # @param [TrueClass|FalseClass] private Whether the method is private or not.
      # @return [String] The generated documentation string for the method.
      def docs_helper(class_name, method_obj, private: false)
        attribute = method_attributes(method_obj)
        <<-DOC
    # +#{class_name}#{attribute[:method_symbol]}#{attribute[:method_name]}+    -> #{attribute[:return_type]}
    #
    # Method documentation.
    #
    #{"# @private\n" if private}#{attribute[:params_block]}# @return [#{attribute[:return_type]}]
    #{attribute[:source]}
        DOC
      end

      # +Generator.method_attributes+                 -> Hash
      #
      # Extracts method attributes for documentation.
      #
      # @private
      # @param [ObjectYARD::CodeObjects::MethodObject] method_obj The method object.
      # @return [Hash] A hash containing method attributes.
      def method_attributes(method_obj)
        { method_name: method_obj.name,
          method_symbol: instance_method?(method_obj) ? "#" : ".",
          return_type: "Object",
          source: method_obj.source.lines.map(&:to_s).join,
          params_block: params_block_helper(method_obj) }
      end

      # +Generator.instance_method?+                  -> TrueClass|FalseClass
      #
      # Determines if a method is an instance method.
      #
      # @private
      # @param [ObjectYARD::CodeObjects::MethodObject] method_obj The method object.
      # @return [TrueClass] True if the method is an instance method
      # @return [FalseClass] False if the method is not an instance method.
      def instance_method?(method_obj)
        method_obj.scope == :instance
      end

      # +Generator.params_block_helper+               -> String
      #
      # Generates the parameters documentation block for a method.
      #
      # @private
      # @param [ObjectYARD::CodeObjects::MethodObject] method_obj The method object.
      # @return [String] The generated parameters documentation block.
      def params_block_helper(method_obj)
        params = params_block(method_obj).join("\n")
        params.empty? ? "" : "#{params}\n"
      end

      # +Generator.params_block+                      -> Array
      #
      # Generates an array of parameter documentation strings for a method.
      #
      # @private
      # @param [ObjectYARD::CodeObjects::MethodObject] method_obj The method object.
      # @return [Array] An array of parameter documentation strings.
      def params_block(method_obj)
        method_obj.parameters.map do |param|
          param_name = param[0]
          param_type = "Object" # You can customize this based on your code analysis
          if (value = param[1]).nil?
            "# @param [#{param_type}] #{param_name} Param documentation."
          elsif could_be_hash?(value) && param_name == "options:"
            "# @option options [Hash] #{param_name} Options documentation."
          elsif param_name.end_with?(":")
            "# @param [#{param[0].class}] #{param_name.chop} Param documentation."
          end
        end
      end

      # +Generator.docstring+                         -> String
      #
      # Generates the final documentation string for a class or module.
      #
      # @private
      # @param [Symbol] struct_type The type of the structure (class or module).
      # @param [Symbol] class_name The name of the class or module.
      # @param [ObjectYARD::CodeObjects::MethodObject] methods The documentation for the methods.
      # @param [String] private_methods_block The documentation for the private methods.
      # @return [String] The final documentation string.
      def docstring(struct_type, class_name, methods, private_methods_block)
        <<~DOC
          #{struct_type} #{class_name}
          #{methods}

          #{private_methods_block}
          end
        DOC
      end
    end
  end
end

# frozen_string_literal: true

RSpec.describe StingrayDocsInternal do
  it "has a version number" do
    expect(StingrayDocsInternal::VERSION).not_to be nil
  end

  it "generate doc for class with one method" do
    code = <<~CODE
      class A
        def abc
          return 123
        end
      end
    CODE

    result = <<~CODE.rstrip
      class A
        # +A#abc+    -> Object
        #
        # Method documentation.
        #
        # @return [Object]
        def abc
          return 123
        end
      end
    CODE

    expect(StingrayDocsInternal::Generator.generate_documentation(code)).to eq(result)
  end

  it "generate doc for class with a lot of methods" do
    code = <<~CODE
      class A
        def foo
          return 123
        end

        def bar
          return 123
        end

        def buzz
          return 123
        end
      end
    CODE

    result = <<~CODE.rstrip
    class A
      # +A#abc+    -> Object
      #
      # Method documentation.
      #
      # @return [Object]
      def abc
        return 123
      end

      # +A#foo+    -> Object
      #
      # Method documentation.
      #
      # @return [Object]
      def foo
        return 123
      end

      # +A#bar+    -> Object
      #
      # Method documentation.
      #
      # @return [Object]
      def bar
        return 123
      end

      # +A#buzz+    -> Object
      #
      # Method documentation.
      #
      # @return [Object]
      def buzz
        return 123
      end
    end
    CODE

    expect(StingrayDocsInternal::Generator.generate_documentation(code)).to eq(result)
  end
end

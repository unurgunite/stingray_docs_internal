# frozen_string_literal: true

RSpec.describe StingrayDocsInternal do
  it "has a version number" do
    expect(StingrayDocsInternal::VERSION).not_to be nil
  end

  it "should generate doc for simple code" do
    code = <<~CODE
      class A
        def abc
          return 123
        end
      end
    CODE

    result = <<~CODE
      # +A#abc+    -> Object
      #
      # Method documentation.
      #
      # @return [Object]
      class A
        def abc
          return 123
        end
      end
    CODE

    expect(StingrayDocsInternal::Generator.generate_documentation(code)).to eq(result)
  end

#   it "does something useful" do
#     expect(false).to eq(true)
#   end
end

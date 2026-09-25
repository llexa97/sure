require "test_helper"

class Provider::Openai::AutoCategorizerTest < ActiveSupport::TestCase
  test "uses default detailed_instructions when family has no custom override" do
    family = families(:dylan_family)
    family.update!(ai_prompt_categorizer_openai: nil)

    categorizer = Provider::Openai::AutoCategorizer.new(nil, family: family)

    assert_includes categorizer.instructions, "consumer personal finance app"
  end

  test "prefers family.ai_prompt_categorizer_openai when set" do
    family = families(:dylan_family)
    family.update!(ai_prompt_categorizer_openai: "Only return JSON, no other text.")

    categorizer = Provider::Openai::AutoCategorizer.new(nil, family: family)

    assert_equal "Only return JSON, no other text.", categorizer.instructions
  end

  test "blank custom override falls back to default" do
    family = families(:dylan_family)
    family.update!(ai_prompt_categorizer_openai: "")

    categorizer = Provider::Openai::AutoCategorizer.new(nil, family: family)

    assert_includes categorizer.instructions, "consumer personal finance app"
  end

  test "nil family does not raise" do
    categorizer = Provider::Openai::AutoCategorizer.new(nil, family: nil)

    assert_includes categorizer.instructions, "consumer personal finance app"
  end
end

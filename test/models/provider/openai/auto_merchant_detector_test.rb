require "test_helper"

class Provider::Openai::AutoMerchantDetectorTest < ActiveSupport::TestCase
  test "uses default detailed_instructions when family has no custom override" do
    family = families(:dylan_family)
    family.update!(ai_prompt_merchant_openai: nil)

    detector = Provider::Openai::AutoMerchantDetector.new(
      nil, transactions: [], user_merchants: [], family: family
    )

    assert_includes detector.instructions, "consumer personal finance app"
  end

  test "prefers family.ai_prompt_merchant_openai when set" do
    family = families(:dylan_family)
    family.update!(ai_prompt_merchant_openai: "Detect merchants. JSON only.")

    detector = Provider::Openai::AutoMerchantDetector.new(
      nil, transactions: [], user_merchants: [], family: family
    )

    assert_equal "Detect merchants. JSON only.", detector.instructions
  end

  test "blank custom override falls back to default" do
    family = families(:dylan_family)
    family.update!(ai_prompt_merchant_openai: "")

    detector = Provider::Openai::AutoMerchantDetector.new(
      nil, transactions: [], user_merchants: [], family: family
    )

    assert_includes detector.instructions, "consumer personal finance app"
  end

  test "nil family does not raise" do
    detector = Provider::Openai::AutoMerchantDetector.new(
      nil, transactions: [], user_merchants: [], family: nil
    )

    assert_includes detector.instructions, "consumer personal finance app"
  end
end

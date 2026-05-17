require "test_helper"

class Settings::AiPromptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "get show" do
    get settings_ai_prompts_url
    assert_response :success
  end

  test "updates custom assistant instructions" do
    patch settings_ai_prompts_url, params: {
      family: { custom_assistant_instructions: "You are a pirate." }
    }

    assert_redirected_to settings_ai_prompts_url
    assert_equal "You are a pirate.", @user.family.reload.custom_assistant_instructions
  end

  test "updates custom auto categorizer instructions" do
    patch settings_ai_prompts_url, params: {
      family: { custom_auto_categorizer_instructions: "Return only JSON." }
    }

    assert_redirected_to settings_ai_prompts_url
    assert_equal "Return only JSON.", @user.family.reload.custom_auto_categorizer_instructions
  end

  test "updates custom auto merchant detector instructions" do
    patch settings_ai_prompts_url, params: {
      family: { custom_auto_merchant_detector_instructions: "Detect merchants." }
    }

    assert_redirected_to settings_ai_prompts_url
    assert_equal "Detect merchants.", @user.family.reload.custom_auto_merchant_detector_instructions
  end

  test "clearing a custom instruction restores default behavior" do
    @user.family.update!(custom_assistant_instructions: "Some override")

    patch settings_ai_prompts_url, params: {
      family: { custom_assistant_instructions: "" }
    }

    assert_redirected_to settings_ai_prompts_url
    assert_equal "", @user.family.reload.custom_assistant_instructions
  end

  test "non-admin cannot view or update" do
    sign_in users(:family_member)

    get settings_ai_prompts_url
    assert_redirected_to accounts_path

    patch settings_ai_prompts_url, params: {
      family: { custom_assistant_instructions: "should not save" }
    }
    assert_redirected_to accounts_path
    assert_nil users(:family_member).family.reload.custom_assistant_instructions
  end
end

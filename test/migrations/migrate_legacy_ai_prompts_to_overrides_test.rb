require "test_helper"
require_relative "../../db/migrate/20260925160000_migrate_legacy_ai_prompts_to_overrides"

class MigrateLegacyAiPromptsToOverridesTest < ActiveSupport::TestCase
  test "moves existing prompts without overwriting edits in the new format" do
    family = families(:dylan_family)
    family.update_columns(
      custom_assistant_instructions: "Legacy assistant",
      custom_auto_categorizer_instructions: "Legacy categorizer",
      custom_auto_merchant_detector_instructions: "Legacy merchant",
      ai_prompt_overrides: { "chat_system" => "New assistant" }
    )

    MigrateLegacyAiPromptsToOverrides.new.up

    assert_equal "New assistant", family.reload.ai_prompt(:chat_system)
    assert_equal "Legacy categorizer", family.ai_prompt(:categorizer_openai)
    assert_equal "Legacy merchant", family.ai_prompt(:merchant_openai)
  end
end

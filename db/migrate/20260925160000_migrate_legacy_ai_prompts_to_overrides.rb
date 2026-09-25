class MigrateLegacyAiPromptsToOverrides < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE families
      SET ai_prompt_overrides = jsonb_strip_nulls(jsonb_build_object(
        'chat_system', NULLIF(custom_assistant_instructions, ''),
        'categorizer_openai', NULLIF(custom_auto_categorizer_instructions, ''),
        'merchant_openai', NULLIF(custom_auto_merchant_detector_instructions, '')
      )) || ai_prompt_overrides
      WHERE NULLIF(custom_assistant_instructions, '') IS NOT NULL
         OR NULLIF(custom_auto_categorizer_instructions, '') IS NOT NULL
         OR NULLIF(custom_auto_merchant_detector_instructions, '') IS NOT NULL
    SQL
  end

  def down
    # Keep prompt edits made after this migration in the new format.
  end
end

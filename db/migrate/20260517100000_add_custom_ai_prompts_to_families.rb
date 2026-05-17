class AddCustomAiPromptsToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :custom_assistant_instructions, :text
    add_column :families, :custom_auto_categorizer_instructions, :text
    add_column :families, :custom_auto_merchant_detector_instructions, :text
  end
end

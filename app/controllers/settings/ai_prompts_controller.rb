class Settings::AiPromptsController < ApplicationController
  layout "settings"

  before_action :require_admin!
  before_action :set_family

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "AI Prompts", nil ]
    ]
    @default_assistant_instructions = Assistant::Builtin.default_instructions_for(@family)
    @default_auto_categorizer_instructions = Provider::Openai::AutoCategorizer
      .new(nil, family: nil)
      .instructions
    @default_auto_merchant_detector_instructions = Provider::Openai::AutoMerchantDetector
      .new(nil, transactions: [], user_merchants: [], family: nil)
      .instructions
  end

  def update
    if @family.update(family_params)
      redirect_to settings_ai_prompts_path, notice: t(".updated")
    else
      redirect_to settings_ai_prompts_path, alert: @family.errors.full_messages.to_sentence
    end
  end

  private

    def set_family
      @family = Current.family
    end

    def family_params
      params.require(:family).permit(
        :custom_assistant_instructions,
        :custom_auto_categorizer_instructions,
        :custom_auto_merchant_detector_instructions
      )
    end
end

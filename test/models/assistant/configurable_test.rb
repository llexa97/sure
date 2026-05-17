require "test_helper"

class AssistantConfigurableTest < ActiveSupport::TestCase
  test "returns dashboard configuration by default" do
    chat = chats(:one)

    config = Assistant.config_for(chat)

    assert_not_empty config[:functions]
    assert_includes config[:instructions], "You help users understand their financial data"
  end

  test "returns intro configuration without functions" do
    chat = chats(:intro)

    config = Assistant.config_for(chat)

    assert_equal [], config[:functions]
    assert_includes config[:instructions], "stage of life"
  end

  test "prefers family custom_assistant_instructions when set" do
    chat = chats(:one)
    chat.user.family.update!(custom_assistant_instructions: "You are a pirate. Answer in pirate-speak.")

    config = Assistant.config_for(chat)

    assert_equal "You are a pirate. Answer in pirate-speak.", config[:instructions]
    assert_not_empty config[:functions]
  end

  test "blank custom_assistant_instructions falls back to default" do
    chat = chats(:one)
    chat.user.family.update!(custom_assistant_instructions: "")

    config = Assistant.config_for(chat)

    assert_includes config[:instructions], "You help users understand their financial data"
  end
end

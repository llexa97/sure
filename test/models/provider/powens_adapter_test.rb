require "test_helper"

class Provider::PowensAdapterTest < ActiveSupport::TestCase
  setup do
    clear_powens_settings
  end

  teardown do
    clear_powens_settings
  end

  test "declares UI configurable Powens credentials" do
    configuration = Provider::PowensAdapter.configuration

    assert_equal "powens", configuration.provider_key
    assert_includes configuration.fields.map(&:setting_key), :powens_domain
    assert_includes configuration.fields.map(&:setting_key), :powens_client_id
    assert_includes configuration.fields.map(&:setting_key), :powens_client_secret
    assert configuration.fields.find { |field| field.name == :client_secret }.secret
  end

  test "supports bank account types only" do
    assert_includes Provider::PowensAdapter.supported_account_types, "Depository"
    assert_includes Provider::PowensAdapter.supported_account_types, "CreditCard"
    assert_includes Provider::PowensAdapter.supported_account_types, "Loan"
    assert_not_includes Provider::PowensAdapter.supported_account_types, "Investment"
  end

  test "returns connection config when configured" do
    family = families(:dylan_family)
    family.stubs(:can_connect_powens?).returns(true)

    config = Provider::PowensAdapter.connection_configs(family: family).first

    assert_equal "powens", config[:key]
    assert_equal "Powens", config[:name]
    assert config[:can_connect]
    assert_equal "/powens_items/new", URI.parse(config[:new_account_path].call("Depository", "/accounts")).path
    assert_equal "/powens_items/select_existing_account", URI.parse(config[:existing_account_path].call(accounts(:depository).id)).path
  end

  test "does not return connection config when not configured" do
    family = families(:dylan_family)
    family.stubs(:can_connect_powens?).returns(false)

    assert_empty Provider::PowensAdapter.connection_configs(family: family)
  end

  test "builds provider from environment configuration" do
    with_env_overrides(
      "POWENS_DOMAIN" => "demo-sandbox",
      "POWENS_CLIENT_ID" => "client_123",
      "POWENS_CLIENT_SECRET" => "secret_456"
    ) do
      provider = Provider::PowensAdapter.build_provider

      assert_instance_of Provider::Powens, provider
      assert_equal "demo-sandbox.biapi.pro", provider.api_host
    end
  end

  test "builds provider from settings UI configuration" do
    Setting["powens_domain"] = "settings-sandbox.biapi.pro"
    Setting["powens_client_id"] = "settings-client"
    Setting["powens_client_secret"] = "settings-secret"

    provider = Provider::PowensAdapter.build_provider

    assert_instance_of Provider::Powens, provider
    assert_equal "settings-sandbox.biapi.pro", provider.api_host
    assert_equal "settings-client", provider.client_id
  end

  private
    def clear_powens_settings
      Setting["powens_domain"] = nil
      Setting["powens_client_id"] = nil
      Setting["powens_client_secret"] = nil
    end
end

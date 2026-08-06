require "test_helper"

class PowensItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)

    @powens_item = PowensItem.create!(
      family: families(:dylan_family),
      name: "Powens Connection",
      domain: "demo-sandbox.biapi.pro",
      user_id: "42",
      access_token: "powens-token",
      connection_id: "99",
      reference: SecureRandom.uuid,
      status: :requires_update
    )
  end

  test "callback processes linked accounts after a successful reconnect import" do
    PowensItem.any_instance
      .expects(:import_latest_powens_data)
      .with(wait_for_source_refresh: true)
      .returns(success: true)
    PowensItem.any_instance.expects(:process_accounts).once
    PowensItem.any_instance.expects(:schedule_account_syncs).once

    get callback_powens_items_url, params: { state: @powens_item.reference }

    assert_redirected_to setup_accounts_powens_item_path(@powens_item)
  end

  test "callback does not process cached accounts after a failed reconnect import" do
    PowensItem.any_instance
      .expects(:import_latest_powens_data)
      .with(wait_for_source_refresh: true)
      .returns(success: false, error: "Powens refresh failed")
    PowensItem.any_instance.expects(:process_accounts).never
    PowensItem.any_instance.expects(:schedule_account_syncs).never

    get callback_powens_items_url, params: { state: @powens_item.reference }

    assert_redirected_to accounts_path
  end
end

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

  test "reconnect uses recovery instead of resetting source credentials" do
    provider = Provider::Powens.new(domain: "demo-sandbox", client_id: "client", client_secret: "secret")
    Provider::PowensAdapter.stubs(:build_provider).returns(provider)
    provider.expects(:get_connection).returns(id: 99, sources: [ { name: "directaccess", state: "SCARequired" } ])
    provider.expects(:generate_temporary_code).returns(code: "temporary")

    get reconnect_powens_item_url(@powens_item)

    assert_response :redirect
    uri = URI.parse(response.location)
    assert_equal "webview.powens.com", uri.host
    params = Rack::Utils.parse_query(uri.query)
    assert_equal "99", params["connection_id"]
    assert_nil params["reset_credentials"]
    assert_nil params["connection_sources"]
  end

  test "callback queues a follow-up for pending refresh without processing cached accounts" do
    PowensItem.any_instance.expects(:import_latest_powens_data)
      .with(wait_for_source_refresh: true).returns(success: false, refresh_pending: true)
    PowensItem.any_instance.expects(:process_accounts).never
    PowensItem.any_instance.expects(:schedule_account_syncs).never

    assert_enqueued_with(job: PowensRefreshJob, args: [ @powens_item ]) do
      get callback_powens_items_url, params: { state: @powens_item.reference }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("powens_items.refresh_pending"), flash[:notice]
    assert_nil flash[:alert]
  end
end

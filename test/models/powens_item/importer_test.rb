require "test_helper"

class PowensItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @powens_item = PowensItem.create!(
      family: families(:dylan_family),
      name: "Powens Connection",
      domain: "demo-sandbox.biapi.pro",
      user_id: "42",
      access_token: "powens-token",
      connection_id: "99",
      reference: SecureRandom.uuid
    )
    @powens_account = PowensAccount.create!(
      powens_item: @powens_item,
      account_id: "11",
      name: "Powens Checking",
      currency: "EUR",
      account_type: "checking"
    )
  end

  test "filters pending transactions by default" do
    Setting.stubs(:syncs_include_pending).returns(false)

    importer = PowensItem::Importer.new(@powens_item, powens_provider: provider_with_transactions)
    result = importer.send(:import_transactions, @powens_account)

    assert_equal 1, result[:count]
    assert_equal [ 1 ], @powens_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "includes pending transactions when Powens env toggle is enabled" do
    Setting.stubs(:syncs_include_pending).returns(false)

    with_env_overrides("POWENS_INCLUDE_PENDING" => "1") do
      importer = PowensItem::Importer.new(@powens_item, powens_provider: provider_with_transactions)
      result = importer.send(:import_transactions, @powens_account)

      assert_equal 2, result[:count]
      assert_equal [ 1, 2 ], @powens_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
    end
  end

  test "omits min date for first transaction import on linked account" do
    AccountProvider.create!(account: accounts(:depository), provider: @powens_account)
    provider = provider_with_transactions

    importer = PowensItem::Importer.new(@powens_item, powens_provider: provider)
    importer.send(:import_transactions, @powens_account)

    assert_nil provider.last_options[:min_date]
  end

  test "uses rolling ninety day lookback after previous transaction import" do
    @powens_item.update!(last_synced_at: Date.current)
    @powens_account.update!(raw_transactions_payload: [ { id: 999, coming: false, wording: "Existing" } ])
    provider = provider_with_transactions

    importer = PowensItem::Importer.new(@powens_item, powens_provider: provider)
    importer.send(:import_transactions, @powens_account)

    assert_equal 90.days.ago.to_date, provider.last_options[:min_date]
  end

  test "does not cap transactions at the server current date" do
    provider = provider_with_transactions

    importer = PowensItem::Importer.new(@powens_item, powens_provider: provider)
    importer.send(:import_transactions, @powens_account)

    assert_not provider.last_options.key?(:max_date)
  end

  test "does not report cached linked-account data as a successful sync when its source needs SCA" do
    AccountProvider.create!(account: accounts(:depository), provider: @powens_account)
    @powens_item.update!(status: :requires_update)
    connection = {
      id: 99,
      state: "SCARequired",
      accounts: [
        { id: 11, id_source: 35, name: "Powens Checking", type: "checking" }
      ],
      sources: [
        { id: 34, name: "openapi", state: nil },
        { id: 35, name: "directaccess", state: "SCARequired" }
      ]
    }
    provider = mock
    provider.expects(:sync_connection).never
    provider.expects(:get_connection)
      .with("powens-token", "99", expand: "accounts,connector,sources")
      .returns(connection)
    provider.expects(:list_account_transactions).never

    result = PowensItem::Importer.new(
      @powens_item,
      powens_provider: provider,
      sync_connection: true
    ).import

    assert_not result[:success]
    assert_match(/directaccess/, result[:error])
    assert_match(/SCARequired/, result[:error])
    assert_predicate @powens_item.reload, :requires_update?
    assert_nil @powens_item.last_synced_at
  end

  test "ignores a global error caused only by an unlinked source" do
    AccountProvider.create!(account: accounts(:depository), provider: @powens_account)
    connection = {
      state: "SCARequired",
      accounts: [
        { id: 11, id_source: 34 },
        { id: 12, id_source: 35 }
      ],
      sources: [
        { id: 34, name: "openapi", state: nil },
        { id: 35, name: "directaccess", state: "SCARequired" }
      ]
    }

    assert_nil @powens_item.connection_issue(connection)
    assert_empty @powens_item.reconnect_source_names(connection)
  end

  test "waits for the affected source to refresh without requiring changed account data" do
    AccountProvider.create!(account: accounts(:depository), provider: @powens_account)
    @powens_account.update!(current_balance: 500)
    @powens_item.update!(
      status: :requires_update,
      raw_connection_payload: {
        accounts: [ { id: 11, id_source: 35 } ],
        sources: [
          { id: 34, name: "openapi", state: nil, last_update: "2026-08-06 10:00:00" },
          { id: 35, name: "directaccess", state: "SCARequired", last_update: "2026-07-14 09:29:39" }
        ]
      }
    )
    pending_connection = {
      id: 99,
      accounts: [ { id: 11, id_source: 35, name: "Powens Checking", type: "checking", balance: 500, currency: "EUR" } ],
      sources: [ { id: 35, name: "directaccess", state: nil, last_update: "2026-07-14 09:29:39" } ]
    }
    refreshed_connection = pending_connection.deep_dup
    refreshed_connection[:sources][0][:last_update] = "2026-08-06 18:45:00"
    provider = mock
    provider.expects(:get_connection)
      .twice
      .with("powens-token", "99", expand: "accounts,connector,sources")
      .returns(pending_connection, refreshed_connection)
    provider.expects(:list_account_transactions).returns(transactions: [])

    result = PowensItem::Importer.new(
      @powens_item,
      powens_provider: provider,
      wait_for_source_refresh: true,
      source_refresh_poll_attempts: 2,
      source_refresh_poll_interval: 0
    ).import

    assert result[:success]
    assert_predicate @powens_item.reload, :good?
    assert_equal 500, @powens_account.reload.current_balance
  end

  test "does not accept an unchanged source timestamp as a completed reconnect" do
    AccountProvider.create!(account: accounts(:depository), provider: @powens_account)
    connection = {
      id: 99,
      accounts: [ { id: 11, id_source: 35, balance: 500 } ],
      sources: [ { id: 35, name: "directaccess", state: nil, last_update: "2026-07-14 09:29:39" } ]
    }
    @powens_item.update!(
      status: :requires_update,
      raw_connection_payload: {
        accounts: [ { id: 11, id_source: 35 } ],
        sources: [ { id: 35, name: "directaccess", state: "SCARequired", last_update: "2026-07-14 09:29:39" } ]
      }
    )
    provider = mock
    provider.expects(:get_connection)
      .with("powens-token", "99", expand: "accounts,connector,sources")
      .returns(connection)
    provider.expects(:list_account_transactions).never

    result = PowensItem::Importer.new(
      @powens_item,
      powens_provider: provider,
      wait_for_source_refresh: true,
      source_refresh_poll_attempts: 1,
      source_refresh_poll_interval: 0
    ).import

    assert_not result[:success]
    assert_match(/cached values were not imported/, result[:error])
    assert_predicate @powens_item.reload, :requires_update?
  end

  private
    def provider_with_transactions
      provider = Object.new
      provider.define_singleton_method(:last_options) { @last_options }
      provider.define_singleton_method(:list_account_transactions) do |_access_token, _account_id, **options|
        @last_options = options
        {
          transactions: [
            { id: 1, coming: "false", wording: "Posted" },
            { id: 2, coming: "true", wording: "Pending" }
          ]
        }
      end
      provider
    end
end

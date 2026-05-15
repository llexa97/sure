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

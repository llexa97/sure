require "test_helper"

class PowensAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @powens_item = PowensItem.create!(
      family: @family,
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
      account_type: "checking",
      current_balance: BigDecimal("1234.56"),
      raw_transactions_payload: [
        {
          id: 123,
          id_account: 11,
          date: "2026-01-15",
          value: "-15.25",
          wording: "CARD PAYMENT",
          coming: true,
          type: "card"
        }
      ]
    )
    AccountProvider.create!(account: @account, provider: @powens_account)
  end

  test "updates linked account balance and imports transactions with Powens metadata" do
    assert_difference "@account.entries.count", 1 do
      PowensAccount::Processor.new(@powens_account).process
    end

    entry = @account.entries.order(created_at: :desc).first

    assert_equal BigDecimal("1234.56"), @account.reload.balance
    assert_equal BigDecimal("1234.56"), @account.cash_balance
    assert_equal "EUR", @account.currency
    assert_equal "powens", entry.source
    assert_equal "powens_123", entry.external_id
    assert_equal BigDecimal("-15.25"), entry.amount
    assert entry.transaction.pending?
    assert_equal true, entry.transaction.extra.dig("powens", "pending")
    assert_equal "123", entry.transaction.extra.dig("powens", "transaction_id").to_s
  end
end

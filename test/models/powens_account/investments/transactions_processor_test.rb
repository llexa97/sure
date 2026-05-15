require "test_helper"

class PowensAccount::Investments::TransactionsProcessorTest < ActiveSupport::TestCase
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
      account_id: "pea-1",
      name: "Trade Republic PEA",
      currency: "EUR",
      account_type: "pea",
      raw_transactions_payload: [
        {
          id: 901,
          id_account: "pea-1",
          date: "2025-10-02",
          value: "5.52",
          wording: "S&P 500 Swap Pea Eur (Acc) Plan d'épargne exécuté",
          type: "market_order"
        },
        {
          id: 902,
          id_account: "pea-1",
          date: "2025-10-03",
          value: "-1.00",
          wording: "CARD PAYMENT",
          type: "card"
        }
      ]
    )
    @account = accounts(:investment)
    @security = securities(:aapl)
    AccountProvider.create!(account: @account, provider: @powens_account)
  end

  test "creates a buy trade for market orders" do
    processor = processor_with_matcher

    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      assert_no_difference "Transaction.count" do
        processor.process
      end
    end

    entry = @account.entries.find_by!(external_id: "powens_901", source: "powens")

    assert entry.trade?
    assert_equal "S&P 500 Swap Pea Eur (Acc) Plan d'épargne exécuté", entry.name
    assert_equal Date.new(2025, 10, 2), entry.date
    assert_equal BigDecimal("5.52"), entry.amount
    assert_equal "EUR", entry.currency
    assert_equal @security, entry.trade.security
    assert_equal BigDecimal("5.647396"), entry.trade.price
    assert_in_delta((BigDecimal("5.52") / BigDecimal("5.647396")).to_f, entry.trade.qty.to_f, 0.000001)
    assert_equal "Buy", entry.trade.investment_activity_label
  end

  test "replaces prior market order cash transaction with trade" do
    @account.entries.create!(
      external_id: "powens_901",
      source: "powens",
      date: Date.new(2025, 10, 2),
      amount: BigDecimal("-5.52"),
      currency: "EUR",
      name: "S&P 500 Swap Pea Eur (Acc) Plan d'épargne exécuté",
      entryable: Transaction.new(extra: { powens: { type: "market_order" } })
    )

    processor = processor_with_matcher

    assert_no_difference "Entry.count" do
      assert_difference "Transaction.count", -1 do
        assert_difference "Trade.count", 1 do
          processor.process
        end
      end
    end

    entry = @account.entries.find_by!(external_id: "powens_901", source: "powens")
    assert entry.trade?
    assert_equal BigDecimal("5.52"), entry.amount
  end

  private
    def processor_with_matcher
      match = PowensAccount::Investments::SecurityMatcher::Match.new(
        security: @security,
        label: "S&P 500 Swap Pea Eur (Acc)",
        normalized_label: "s p 500 swap pea eur acc",
        unit_price: BigDecimal("5.647396"),
        currency: "EUR"
      )
      matcher = mock("Powens security matcher")
      matcher.expects(:match)
        .with("S&P 500 Swap Pea Eur (Acc) Plan d'épargne exécuté")
        .returns(match)

      PowensAccount::Investments::TransactionsProcessor.new(@powens_account, security_matcher: matcher)
    end
end

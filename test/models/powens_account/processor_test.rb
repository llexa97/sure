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
    assert_equal "Depository", @account.accountable_type

    assert_difference "@account.entries.count", 1 do
      assert_no_difference "Valuation.count" do
        PowensAccount::Processor.new(@powens_account).process
      end
    end

    entry = @account.entries.find_by!(external_id: "powens_123", source: "powens")

    assert_equal BigDecimal("1234.56"), @account.reload.balance
    assert_equal BigDecimal("1234.56"), @account.cash_balance
    assert_equal "EUR", @account.currency
    assert_not @account.valuations.current_anchor.exists?
    assert_equal "powens", entry.source
    assert_equal "powens_123", entry.external_id
    assert_equal BigDecimal("15.25"), entry.amount
    assert entry.transaction.pending?
    assert_equal true, entry.transaction.extra.dig("powens", "pending")
    assert_equal "123", entry.transaction.extra.dig("powens", "transaction_id").to_s
    assert_equal "-15.25", entry.transaction.extra.dig("powens", "raw_value")
    assert_equal "sure_expense_positive", entry.transaction.extra.dig("powens", "amount_convention")
  end

  test "updates an existing current anchor in place without adding balance entries" do
    @powens_account.update!(raw_transactions_payload: [])
    current_anchor = @account.entries.create!(
      date: 2.days.ago.to_date,
      name: Valuation.build_current_anchor_name(@account.accountable_type),
      amount: BigDecimal("1200"),
      currency: @account.currency,
      entryable: Valuation.new(kind: "current_anchor")
    ).entryable

    assert_no_difference [ "Entry.count", "Valuation.count" ] do
      PowensAccount::Processor.new(@powens_account).process
    end

    current_anchor.reload
    assert_equal "current_anchor", current_anchor.kind
    assert_equal BigDecimal("1234.56"), current_anchor.entry.amount
    assert_equal Date.current, current_anchor.entry.date
    assert_equal "EUR", current_anchor.entry.currency
  end

  test "stores loan balances as positive liabilities" do
    loan_account = accounts(:loan)
    powens_loan = PowensAccount.create!(
      powens_item: @powens_item,
      account_id: "12",
      name: "Powens Loan",
      currency: "EUR",
      account_type: "loan",
      current_balance: BigDecimal("-13960.44"),
      raw_transactions_payload: []
    )
    AccountProvider.create!(account: loan_account, provider: powens_loan)

    assert_no_difference "Valuation.count" do
      PowensAccount::Processor.new(powens_loan).process
    end

    assert_equal BigDecimal("13960.44"), loan_account.reload.balance
    assert_equal BigDecimal("13960.44"), loan_account.cash_balance
  end

  test "imports investment market orders as trades and keeps other transactions as cash entries" do
    investment_account = accounts(:investment)
    powens_investment = PowensAccount.create!(
      powens_item: @powens_item,
      account_id: "13",
      name: "Trade Republic PEA",
      currency: "EUR",
      account_type: "pea",
      current_balance: BigDecimal("231.95"),
      raw_holdings_payload: {
        investments: [
          {
            id: "holding-1",
            id_account: "13",
            code: "FR0013412285",
            code_type: "ISIN",
            label: "S&P 500 Swap Pea Eur (Acc)",
            quantity: "38",
            unitprice: "5.647396",
            unitvalue: "6.103947",
            valuation: "231.95",
            original_currency: { id: "EUR" },
            vdate: "2026-05-15"
          }
        ]
      },
      raw_transactions_payload: [
        {
          id: 901,
          id_account: "13",
          date: "2025-10-02",
          value: "5.52",
          wording: "S&P 500 Swap Pea Eur (Acc) Plan d'épargne exécuté",
          type: "market_order"
        },
        {
          id: 902,
          id_account: "13",
          date: "2025-10-03",
          value: "-1.00",
          wording: "FRAIS",
          type: "fee"
        }
      ]
    )
    AccountProvider.create!(account: investment_account, provider: powens_investment)

    security = securities(:aapl)
    upstream_resolver = mock("Security::Resolver")
    Security::Resolver.expects(:new).with("FR0013412285").returns(upstream_resolver)
    upstream_resolver.expects(:resolve).returns(security)

    assert_difference [ "Trade.count", "Transaction.count", "Holding.count" ], 1 do
      PowensAccount::Processor.new(powens_investment).process
    end

    market_order = investment_account.entries.find_by!(external_id: "powens_901", source: "powens")
    fee = investment_account.entries.find_by!(external_id: "powens_902", source: "powens")

    assert market_order.trade?
    assert_equal BigDecimal("5.52"), market_order.amount
    assert_equal "Buy", market_order.trade.investment_activity_label
    assert fee.transaction?
    assert_equal BigDecimal("1.00"), fee.amount
    assert_equal BigDecimal("231.95"), investment_account.reload.balance
    assert_equal 0, investment_account.cash_balance
    assert_equal "EUR", investment_account.currency
  end
end

require "test_helper"

class PowensAccount::Investments::SecurityMatcherTest < ActiveSupport::TestCase
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
      raw_holdings_payload: {
        investments: [
          {
            id: "holding-1",
            id_account: "pea-1",
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
      }
    )
    AccountProvider.create!(account: accounts(:investment), provider: @powens_account)
  end

  test "matches a market order wording to the holding label prefix" do
    security = securities(:aapl)
    resolver = mock("Powens security resolver")
    resolver.expects(:resolve)
      .with(ticker: nil, isin: "FR0013412285", name: "S&P 500 Swap Pea Eur (Acc)")
      .returns(OpenStruct.new(security: security))

    matcher = PowensAccount::Investments::SecurityMatcher.new(@powens_account, security_resolver: resolver)
    match = matcher.match("S&P 500 Swap Pea Eur (Acc) Plan d'épargne exécuté")

    assert_equal security, match.security
    assert_equal "S&P 500 Swap Pea Eur (Acc)", match.label
    assert_equal BigDecimal("5.647396"), match.unit_price
    assert_equal "EUR", match.currency
  end
end

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

  test "uses the holding security mapping for subsequent market orders" do
    holding = create_remapped_holding

    match = match_provider_security

    assert_equal holding.security, match.security
    assert_equal BigDecimal("5.647396"), match.unit_price
    assert_equal "EUR", match.currency
  end

  test "does not use another account's security mapping" do
    create_remapped_holding(account: accounts(:depository))

    assert_equal securities(:aapl), match_provider_security.security
  end

  test "does not use another provider's security mapping" do
    other_provider = AccountProvider.create!(account: accounts(:investment), provider: plaid_accounts(:one))
    create_remapped_holding(account_provider: other_provider)

    assert_equal securities(:aapl), match_provider_security.security
  end

  test "does not use a manual holding's security mapping" do
    create_remapped_holding(account_provider: nil)

    assert_equal securities(:aapl), match_provider_security.security
  end

  test "does not use an unlocked security mapping" do
    create_remapped_holding(security_locked: false)

    assert_equal securities(:aapl), match_provider_security.security
  end

  private
    def create_remapped_holding(**attributes)
      Holding.create!({
        account: accounts(:investment),
        account_provider: @powens_account.account_provider,
        provider_security: securities(:aapl),
        security: securities(:msft),
        security_locked: true,
        date: Date.current,
        qty: 38,
        price: 6,
        amount: 228,
        currency: "EUR"
      }.merge(attributes))
    end

    def match_provider_security
      resolver = mock("Powens security resolver")
      resolver.expects(:resolve).returns(OpenStruct.new(security: securities(:aapl)))
      matcher = PowensAccount::Investments::SecurityMatcher.new(@powens_account, security_resolver: resolver)
      matcher.match("S&P 500 Swap Pea Eur (Acc) Plan d'épargne exécuté")
    end
end

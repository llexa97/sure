require "test_helper"

class PowensAccountTest < ActiveSupport::TestCase
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
  end

  test "suggests loan for French pret account type" do
    account = PowensAccount.new(
      powens_item: @powens_item,
      account_id: "pret-1",
      name: "Pret Multiprojets",
      account_type: "prêt",
      current_balance: BigDecimal("-13960.44")
    )

    assert_equal "Loan", account.suggested_account_type
    assert_equal BigDecimal("13960.44"), account.current_balance_for("Loan")
  end
end

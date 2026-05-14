require "test_helper"

class PowensAccount::NormalizerTest < ActiveSupport::TestCase
  test "builds account name from provider name, masked identifier, and currency" do
    name = PowensAccount::Normalizer.account_name(
      {
        original_name: "Compte courant",
        iban: "FR7612345678901234567890185",
        currency: { id: "EUR" }
      }
    )

    assert_equal "Compte courant (XXX 0185) EUR", name
  end

  test "normalizes posted transaction payload" do
    transaction = PowensAccount::Normalizer.normalize_transaction(
      {
        id: 123,
        id_account: 11,
        application_date: "2026-01-15",
        date: "2026-01-16",
        value: "-42.50",
        wording: "CARTE RESTAURANT",
        original_wording: "PAIEMENT CARTE RESTAURANT",
        coming: false
      },
      account_currency: "EUR"
    )

    assert_equal "powens_123", transaction[:external_id]
    assert_equal BigDecimal("-42.50"), transaction[:amount]
    assert_equal Date.new(2026, 1, 15), transaction[:date]
    assert_equal "EUR", transaction[:currency]
    assert_equal "CARTE RESTAURANT", transaction[:name]
    assert_not transaction[:pending]
    assert_equal "PAIEMENT CARTE RESTAURANT", transaction[:notes]
  end

  test "normalizes pending transaction from coming flag" do
    transaction = PowensAccount::Normalizer.normalize_transaction(
      {
        id_account: 11,
        date: "2026-01-15",
        gross_value: "12.34",
        simplified_wording: "Pending card",
        coming: true
      },
      account_currency: "EUR"
    )

    assert_match(/\Apowens_hash_/, transaction[:external_id])
    assert transaction[:pending]
  end

  test "returns nil when required transaction fields are missing" do
    assert_nil PowensAccount::Normalizer.normalize_transaction({ id: 123, value: "10" }, account_currency: "EUR")
    assert_nil PowensAccount::Normalizer.normalize_transaction({ id: 123, date: "2026-01-15" }, account_currency: "EUR")
  end
end

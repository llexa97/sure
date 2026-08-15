require "test_helper"

class UI::Account::PendingBalanceSummaryTest < ViewComponent::TestCase
  setup do
    @account = accounts(:depository)
    @account.update!(balance: 5000, cash_balance: 5000, classification: :asset)
  end

  test "renders the net pending impact and estimated asset balance" do
    create_entry(amount: 100, provider: "gocardless", pending: true)
    create_entry(amount: -25, provider: "powens", pending: true)

    render_inline(UI::Account::PendingBalanceSummary.new(account: @account))

    assert_selector "section[data-testid='pending-balance-summary']"
    assert_text "2 pending transactions"
    assert_selector "[data-testid='pending-balance-effect']", text: "-$75.00"
    assert_selector "[data-testid='estimated-balance-after-pending']", text: "$4,925.00"
  end

  test "does not render when pending transactions are confirmed or excluded" do
    create_entry(amount: 100, provider: "powens", pending: false)
    create_entry(amount: 50, provider: "gocardless", pending: true, excluded: true)

    render_inline(UI::Account::PendingBalanceSummary.new(account: @account))

    assert_no_selector "section[data-testid='pending-balance-summary']"
  end

  test "pending charges increase the estimated balance of a liability" do
    account = accounts(:credit_card)
    account.update!(balance: 1000, cash_balance: 1000, classification: :liability)
    create_entry(account: account, amount: 50, provider: "powens", pending: true)

    render_inline(UI::Account::PendingBalanceSummary.new(account: account))

    assert_selector "[data-testid='pending-balance-effect'].text-warning", text: "+$50.00"
    assert_selector "[data-testid='estimated-balance-after-pending']", text: "$1,050.00"
  end

  test "renders the French labels used by the production account" do
    @account.update!(balance: 701.85, cash_balance: 701.85, currency: "EUR")
    create_entry(amount: 94.51, provider: "gocardless", pending: true)

    I18n.with_locale(:fr) do
      render_inline(UI::Account::PendingBalanceSummary.new(account: @account))
    end

    assert_text "Solde avec les opérations en attente"
    assert_text "1 opération en attente"
    assert_text "Solde estimé après les opérations"
    assert_selector "[data-testid='pending-balance-effect']", text: "-94,51\u00A0€"
    assert_selector "[data-testid='estimated-balance-after-pending']", text: "607,34\u00A0€"
  end

  private
    def create_entry(account: @account, amount:, provider:, pending:, excluded: false)
      account.entries.create!(
        name: "Pending transaction",
        date: Date.current,
        amount: amount,
        currency: account.currency,
        source: provider,
        external_id: SecureRandom.uuid,
        excluded: excluded,
        entryable: Transaction.new(extra: { provider => { "pending" => pending } })
      )
    end
end

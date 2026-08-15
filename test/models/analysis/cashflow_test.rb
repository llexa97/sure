require "test_helper"

class Analysis::CashflowTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @family.accounts.each { |account| account.entries.destroy_all }
    @category = @family.categories.create!(
      name: "Analysis groceries",
      color: "#4da568",
      lucide_icon: "shopping-bag"
    )
  end

  test "builds selected-period summaries and an annual aggregate of checking accounts" do
    travel_to Date.new(2026, 8, 15) do
      second_checking = create_depository_account(name: "Second analysis checking", subtype: "checking")
      savings = create_depository_account(name: "Excluded analysis savings", subtype: "savings")

      create_transaction(account: @account, date: Date.new(2026, 8, 5), amount: -500, name: "Current income")
      create_transaction(account: @account, date: Date.new(2026, 8, 10), amount: 125, category: @category, name: "Current expense")
      create_transaction(account: @account, date: Date.new(2026, 7, 5), amount: -400, name: "Previous income")
      create_transaction(account: @account, date: Date.new(2026, 7, 10), amount: 100, category: @category, name: "Previous expense")
      create_transaction(account: @account, date: Date.new(2026, 1, 4), amount: -100, name: "First account January income")
      create_transaction(account: @account, date: Date.new(2026, 1, 9), amount: 50, category: @category, name: "First account January expense")
      create_transaction(account: second_checking, date: Date.new(2026, 1, 5), amount: -200, name: "Second account income")
      create_transaction(account: second_checking, date: Date.new(2026, 1, 10), amount: 50, category: @category, name: "Second account expense")
      create_transaction(account: savings, date: Date.new(2026, 1, 6), amount: -999, name: "Savings income")
      create_transaction(account: savings, date: Date.new(2026, 1, 11), amount: 999, category: @category, name: "Savings expense")

      analysis = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "monthly",
        anchor_date: "2026-08-04"
      )

      assert_equal Date.new(2026, 8, 1), analysis.period.start_date
      assert_equal Date.new(2026, 8, 15), analysis.period.end_date
      assert_equal Date.new(2026, 7, 1), analysis.previous_period.start_date
      assert_equal Date.new(2026, 7, 15), analysis.previous_period.end_date
      assert_equal 500, analysis.summary[:income].amount
      assert_equal 125, analysis.summary[:expense].amount
      assert_equal 375, analysis.summary[:net].amount
      assert_equal 75, analysis.summary[:savings_rate]
      assert_equal 25, analysis.summary[:income_change]
      assert_equal 25, analysis.summary[:expense_change]

      assert_includes analysis.checking_accounts, @account
      assert_includes analysis.checking_accounts, second_checking
      assert_not_includes analysis.checking_accounts, savings
      assert_equal Date.new(2026, 1, 1), analysis.annual_period.start_date
      assert_equal Date.new(2026, 8, 15), analysis.annual_period.end_date
      assert_equal 8, analysis.annual_bars.size
      assert analysis.annual_bars.last[:partial]
      assert_equal 1200, analysis.annual_bars.sum { |bar| bar[:income] }
      assert_equal 325, analysis.annual_bars.sum { |bar| bar[:expense] }
      assert_equal 1200, analysis.annual_summary[:income].amount
      assert_equal 325, analysis.annual_summary[:expense].amount
      assert_equal 875, analysis.annual_summary[:net].amount
      assert_equal 875, analysis.cumulative_net_series.last.value.amount

      legend = analysis.annual_account_legend
      assert_includes legend.pluck(:id), @account.id.to_s
      assert_includes legend.pluck(:id), second_checking.id.to_s
      assert_not_includes legend.pluck(:id), savings.id.to_s
      assert_equal legend.size, legend.pluck(:color).uniq.size

      january_accounts = analysis.annual_bars.first[:accounts].index_by { |account| account[:id] }
      first_account = january_accounts.fetch(@account.id.to_s)
      assert_equal 100, first_account[:income]
      assert_equal 50, first_account[:expense]
      assert_equal 33.3, first_account[:income_percentage]
      assert_equal 50, first_account[:expense_percentage]

      second_account = january_accounts.fetch(second_checking.id.to_s)
      assert_equal 200, second_account[:income]
      assert_equal 50, second_account[:expense]
      assert_equal 66.7, second_account[:income_percentage]
      assert_equal 50, second_account[:expense_percentage]
      assert_not january_accounts.key?(savings.id.to_s)

      account_row = analysis.annual_account_breakdown.find { |row| row[:id] == second_checking.id.to_s }
      assert_equal 200, account_row[:income].amount
      assert_equal 50, account_row[:expense].amount
      assert_equal 150, account_row[:net].amount

      category = analysis.expense_categories.find { |item| item[:id] == @category.id.to_s }
      assert_equal 125, category[:amount].amount
      assert_equal 25, category[:change]
      assert_equal 125, analysis.expense_total.amount
    end
  end

  test "details net expenses under Depenses courantes subcategories" do
    travel_to Date.new(2026, 8, 15) do
      parent = @family.categories.create!(
        name: "Dépenses courantes",
        color: "#6471eb",
        lucide_icon: "wallet-cards"
      )
      groceries = @family.categories.create!(
        name: "Analysis course",
        color: "#6471eb",
        lucide_icon: "shopping-bag",
        parent: parent
      )
      restaurants = @family.categories.create!(
        name: "Analysis resto",
        color: "#6471eb",
        lucide_icon: "utensils",
        parent: parent
      )

      create_transaction(account: @account, date: Date.new(2026, 8, 2), amount: 100, category: groceries, name: "Groceries")
      create_transaction(account: @account, date: Date.new(2026, 8, 3), amount: -20, category: groceries, name: "Groceries refund")
      create_transaction(account: @account, date: Date.new(2026, 8, 4), amount: 60, category: restaurants, name: "Restaurant")
      create_transaction(account: @account, date: Date.new(2026, 8, 5), amount: 10, category: parent, name: "Direct parent expense")
      create_transaction(account: @account, date: Date.new(2026, 8, 6), amount: 999, category: @category, name: "Other root expense")
      create_transaction(account: @account, date: Date.new(2026, 7, 2), amount: 40, category: groceries, name: "Previous groceries")

      analysis = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "monthly",
        anchor_date: "2026-08-10"
      )

      assert_equal parent, analysis.expense_category_parent
      assert_equal 3, analysis.expense_categories.size
      assert_not analysis.expense_categories.any? { |category| category[:id] == @category.id.to_s }

      groceries_row = analysis.expense_categories.find { |category| category[:id] == groceries.id.to_s }
      assert_equal 80, groceries_row[:amount].amount
      assert_equal 40, groceries_row[:previous_amount].amount
      assert_equal 100, groceries_row[:change]

      direct_row = analysis.expense_categories.find { |category| category[:id] == "#{parent.id}-direct" }
      assert_equal 10, direct_row[:amount].amount
      assert_equal I18n.t("analyses.show.categories.without_subcategory"), direct_row[:display_name]
      assert_equal 150, analysis.expense_total.amount
      assert_operator analysis.expense_categories.map { |category| category[:color] }.uniq.size, :>, 1
    end
  end

  test "supports quarter and year periods independently from the annual chart year" do
    travel_to Date.new(2026, 8, 15) do
      quarterly = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "quarterly",
        anchor_date: "2026-05-10",
        cashflow_year: "2025"
      )

      assert_equal Date.new(2026, 4, 1), quarterly.period.start_date
      assert_equal Date.new(2026, 6, 30), quarterly.period.end_date
      assert_equal 2025, quarterly.cashflow_year
      assert_equal Date.new(2025, 1, 1), quarterly.annual_period.start_date
      assert_equal Date.new(2025, 12, 31), quarterly.annual_period.end_date
      assert_equal 12, quarterly.annual_bars.size
      assert_not quarterly.latest_period?
      assert_not quarterly.latest_cashflow_year?

      yearly = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "yearly",
        anchor_date: "2026-08-15"
      )

      assert_equal Date.new(2026, 1, 1), yearly.period.start_date
      assert_equal Date.new(2026, 8, 15), yearly.period.end_date
      assert_equal Date.new(2025, 1, 1), yearly.previous_period.start_date
      assert_equal Date.new(2025, 8, 15), yearly.previous_period.end_date
      assert_equal 8, yearly.annual_bars.size
      assert yearly.latest_period?
      assert yearly.latest_cashflow_year?
    end
  end

  test "falls back safely for invalid values and clamps future dates and years" do
    travel_to Date.new(2026, 8, 15) do
      analysis = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "unsupported",
        anchor_date: "2030-01-01",
        cashflow_year: "2030"
      )

      assert_equal "monthly", analysis.period_type
      assert_equal Date.current, analysis.anchor_date
      assert_equal Date.new(2026, 8, 1), analysis.period.start_date
      assert_equal Date.current, analysis.period.end_date
      assert_equal 2026, analysis.cashflow_year

      invalid = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "monthly",
        anchor_date: "not-a-date",
        cashflow_year: "not-a-year"
      )

      assert_equal Date.current, invalid.anchor_date
      assert_equal Date.current.year, invalid.cashflow_year
    end
  end

  private
    def create_depository_account(name:, subtype:)
      @family.accounts.create!(
        owner: @user,
        name: name,
        currency: @family.currency,
        balance: 0,
        accountable: Depository.new(subtype: subtype)
      )
    end
end

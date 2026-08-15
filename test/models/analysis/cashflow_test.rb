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

  test "builds a comparable monthly cashflow analysis" do
    travel_to Date.new(2026, 8, 15) do
      create_transaction(account: @account, date: Date.new(2026, 8, 5), amount: -500, name: "Current income")
      create_transaction(account: @account, date: Date.new(2026, 8, 10), amount: 125, category: @category, name: "Current expense")
      create_transaction(account: @account, date: Date.new(2026, 7, 5), amount: -400, name: "Previous income")
      create_transaction(account: @account, date: Date.new(2026, 7, 10), amount: 100, category: @category, name: "Previous expense")

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

      assert_equal 500, analysis.bars.sum { |bar| bar[:income] }
      assert_equal 125, analysis.bars.sum { |bar| bar[:expense] }
      assert_equal 3, analysis.bars.size
      assert analysis.bars.last[:partial]

      category = analysis.expense_categories.find { |item| item[:id] == @category.id.to_s }
      assert_equal 125, category[:amount].amount
      assert_equal 100, category[:percentage]
      assert_equal 25, category[:change]
      assert_equal 125, analysis.expense_total.amount
    end
  end

  test "supports complete quarter and year periods" do
    travel_to Date.new(2026, 8, 15) do
      quarterly = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "quarterly",
        anchor_date: "2026-05-10"
      )

      assert_equal Date.new(2026, 4, 1), quarterly.period.start_date
      assert_equal Date.new(2026, 6, 30), quarterly.period.end_date
      assert_equal 3, quarterly.bars.size
      assert_not quarterly.latest_period?

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
      assert_equal 8, yearly.bars.size
      assert yearly.latest_period?
    end
  end

  test "falls back safely for invalid values and clamps future dates" do
    travel_to Date.new(2026, 8, 15) do
      analysis = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "unsupported",
        anchor_date: "2030-01-01"
      )

      assert_equal "monthly", analysis.period_type
      assert_equal Date.current, analysis.anchor_date
      assert_equal Date.new(2026, 8, 1), analysis.period.start_date
      assert_equal Date.current, analysis.period.end_date

      invalid_date = Analysis::Cashflow.new(
        family: @family,
        user: @user,
        period_type: "monthly",
        anchor_date: "not-a-date"
      )

      assert_equal Date.current, invalid_date.anchor_date
    end
  end
end

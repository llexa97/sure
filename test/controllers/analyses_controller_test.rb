require "test_helper"

class AnalysesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @spending_parent = @family.categories.create!(
      name: "Dépenses courantes",
      color: "#e99537",
      lucide_icon: "wallet-cards"
    )
    @category = @family.categories.create!(
      name: "Analysis dining",
      color: "#e99537",
      lucide_icon: "utensils",
      parent: @spending_parent
    )
  end

  test "show renders annual checking charts detailed expenses and data studies" do
    chart_account = @family.accounts.create!(
      owner: @user,
      name: "Analysis chart checking",
      currency: @family.currency,
      balance: 0,
      accountable: Depository.new(subtype: "checking")
    )
    create_transaction(
      account: chart_account,
      date: Date.current,
      amount: 84.25,
      category: @category,
      name: "Analysis dinner"
    )

    get analysis_path

    assert_response :ok
    assert_select "h1", text: I18n.t("analyses.show.title")
    assert_select "a[href=?]", analysis_path, minimum: 1
    assert_select "[data-controller='bar-chart'][data-bar-chart-stacked-value='true']", count: 1
    assert_select "[data-controller='time-series-chart']", count: 1
    assert_select "[data-controller='donut-chart']", count: 2
    assert_select "#expense-breakdown-title", text: I18n.t("analyses.show.categories.detailed_title")
    assert_select "[data-category-id=?]", @category.id.to_s, minimum: 1
    assert_select "#annual-highlights-title", text: I18n.t("analyses.show.highlights.title")
    assert_select "#account-breakdown-title", text: I18n.t("analyses.show.accounts.title")
    assert_select "button[disabled][aria-label=?]", I18n.t("analyses.show.next_period")
    assert_select "button[disabled][aria-label=?]", I18n.t("analyses.show.chart.next_year")

    annual_bars = JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
    assert_equal Date.current.month, annual_bars.size
    current_month = annual_bars.last
    account_segment = current_month.fetch("accounts").find { |account| account["id"] == chart_account.id.to_s }
    assert_not_nil account_segment
    assert_equal 84.25, account_segment["expense"]
    assert_operator account_segment["expense_percentage"], :>, 0

    category_link = css_select("a[data-category-id='#{@category.id}']").first
    assert_not_nil category_link
    category_query = Rack::Utils.parse_nested_query(URI.parse(category_link["href"]).query)
    assert_equal [ @category.name ], category_query.dig("q", "categories")
    assert_equal [ "confirmed" ], category_query.dig("q", "status")

    account_link = css_select("a[data-category-id='#{accounts(:depository).id}']").first
    assert_not_nil account_link
    account_query = Rack::Utils.parse_nested_query(URI.parse(account_link["href"]).query)
    assert_equal [ accounts(:depository).id.to_s ], account_query.dig("q", "account_ids")
  end

  test "show keeps the selected analysis level separate from the annual chart year" do
    travel_to Date.new(2026, 8, 15) do
      create_transaction(
        account: accounts(:depository),
        date: Date.new(2026, 5, 10),
        amount: 42,
        category: @category,
        name: "Quarter analysis expense"
      )
      create_transaction(
        account: accounts(:depository),
        date: Date.new(2025, 5, 10),
        amount: 21,
        category: @category,
        name: "Previous annual analysis expense"
      )

      get analysis_path(period_type: "quarterly", anchor_date: "2026-05-10", cashflow_year: "2025")

      assert_response :ok
      annual_bars = JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
      assert_equal 12, annual_bars.size
      assert_select "a[aria-current='true']", text: I18n.t("analyses.show.periods.quarterly")
      assert_select "a[href*='cashflow_year=2024']", minimum: 1

      get analysis_path(period_type: "yearly", anchor_date: "2026-08-15", cashflow_year: "2026")

      assert_response :ok
      current_year_bars = JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
      assert_equal 8, current_year_bars.size
      assert_select "a[aria-current='true']", text: I18n.t("analyses.show.periods.yearly")
    end
  end

  test "show handles invalid and future parameters" do
    travel_to Date.new(2026, 8, 15) do
      get analysis_path(period_type: "invalid", anchor_date: "2030-01-01", cashflow_year: "2030")

      assert_response :ok
      assert_select "a[aria-current='true']", text: I18n.t("analyses.show.periods.monthly")
      assert_select "button[disabled][aria-label=?]", I18n.t("analyses.show.next_period")
      assert_select "button[disabled][aria-label=?]", I18n.t("analyses.show.chart.next_year")
      annual_bars = JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
      assert_equal 8, annual_bars.size

      get analysis_path(period_type: "monthly", anchor_date: "not-a-date", cashflow_year: "not-a-year")
      assert_response :ok
    end
  end

  test "show never includes another family's accounts or categories" do
    other_family = Family.create!(name: "Other analysis family", currency: "USD")
    other_category = other_family.categories.create!(
      name: "Private other-family spending",
      color: "#6471eb",
      lucide_icon: "shopping-cart"
    )
    other_account = other_family.accounts.create!(
      name: "Private other-family checking",
      currency: "USD",
      balance: 0,
      accountable: Depository.new(subtype: "checking")
    )
    create_transaction(
      account: other_account,
      date: Date.current,
      amount: 999,
      category: other_category,
      name: "Must not render"
    )

    get analysis_path

    assert_response :ok
    assert_no_match other_category.name, response.body
    assert_no_match other_account.name, response.body
  end
end

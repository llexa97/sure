require "test_helper"

class AnalysesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @category = @family.categories.create!(
      name: "Analysis dining",
      color: "#e99537",
      lucide_icon: "utensils"
    )
  end

  test "show renders navigation, summaries and interactive charts" do
    create_transaction(
      account: accounts(:depository),
      date: Date.current,
      amount: 84.25,
      category: @category,
      name: "Analysis dinner"
    )

    get analysis_path

    assert_response :ok
    assert_select "h1", text: I18n.t("analyses.show.title")
    assert_select "a[href=?]", analysis_path, minimum: 1
    assert_select "[data-controller='bar-chart']", count: 1
    assert_select "[data-controller='donut-chart']", count: 1
    assert_select "[data-category-id=?]", @category.id.to_s, minimum: 1
    assert_select "button[disabled][aria-label=?]", I18n.t("analyses.show.next_period")

    category_link = css_select("a[data-category-id='#{@category.id}']").first
    assert_not_nil category_link
    query = Rack::Utils.parse_nested_query(URI.parse(category_link["href"]).query)
    assert_equal [ @category.name ], query.dig("q", "categories")
    assert_equal [ "confirmed" ], query.dig("q", "status")
  end

  test "show renders quarter and year analysis levels" do
    travel_to Date.new(2026, 8, 15) do
      create_transaction(
        account: accounts(:depository),
        date: Date.new(2026, 5, 10),
        amount: 42,
        category: @category,
        name: "Quarter analysis expense"
      )

      get analysis_path(period_type: "quarterly", anchor_date: "2026-05-10")

      assert_response :ok
      quarterly_bars = JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
      assert_equal 3, quarterly_bars.size
      assert_select "a[aria-current='true']", text: I18n.t("analyses.show.periods.quarterly")

      get analysis_path(period_type: "yearly", anchor_date: "2026-08-15")

      assert_response :ok
      yearly_bars = JSON.parse(css_select("[data-controller='bar-chart']").first["data-bar-chart-data-value"])
      assert_equal 8, yearly_bars.size
      assert_select "a[aria-current='true']", text: I18n.t("analyses.show.periods.yearly")
    end
  end

  test "show handles invalid and future parameters" do
    travel_to Date.new(2026, 8, 15) do
      get analysis_path(period_type: "invalid", anchor_date: "2030-01-01")

      assert_response :ok
      assert_select "a[aria-current='true']", text: I18n.t("analyses.show.periods.monthly")
      assert_select "button[disabled][aria-label=?]", I18n.t("analyses.show.next_period")

      get analysis_path(period_type: "monthly", anchor_date: "not-a-date")
      assert_response :ok
    end
  end

  test "show never includes another family's categories" do
    other_family = Family.create!(name: "Other analysis family", currency: "USD")
    other_category = other_family.categories.create!(
      name: "Private other-family spending",
      color: "#6471eb",
      lucide_icon: "shopping-cart"
    )
    other_account = other_family.accounts.create!(
      name: "Other checking",
      currency: "USD",
      balance: 0,
      accountable: Depository.new
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
  end
end

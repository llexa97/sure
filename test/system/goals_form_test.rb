require "application_system_test_case"

# The goal form swaps the amount field's label between "Target amount" and
# "Target balance" as the kind changes. The label also carries the
# required-field asterisk, in a span of its own, so how that swap is made
# decides whether the asterisk survives it — and only a browser can say.
class GoalsFormTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    # Goals sit behind the preview gate; without it the visit redirects to the
    # dashboard and the form never renders.
    @user.update!(
      locale: "en",
      preferences: (@user.preferences || {}).merge("preview_features_enabled" => true)
    )
    sign_in_without_localized_labels @user
  end

  test "the required asterisk survives the label swap" do
    visit new_goal_path

    # This first check is the one that bites: `refresh()` runs on connect, so a
    # swap that replaced the label's children has already wiped the asterisk by
    # the time the page is idle — on every goal form, one-off included, with
    # nothing to put it back.
    label = find(".form-field__label", text: I18n.t("goals.form.fields.target_amount"))
    assert label.has_css?("span", text: "*"),
           "the required marker was gone before anything was even clicked"

    choose I18n.t("goals.form.kinds.maintained.label")

    swapped = find(".form-field__label", text: I18n.t("goals.form.fields.target_balance"))
    assert swapped.has_css?("span", text: "*"),
           "the label swap deleted the required marker"
  end

  test "a months-of-expenses reserve can be submitted without a typed amount" do
    account = Account.create!(
      family: @user.family,
      accountable: Depository.new,
      name: "Emergency reserve account",
      currency: "USD",
      balance: 1_000
    )
    IncomeStatement.any_instance.stubs(:median_expense).returns(500)

    visit new_goal_path
    fill_in I18n.t("goals.form.fields.name"), with: "Emergency reserve"
    choose I18n.t("goals.form.kinds.maintained.label")
    select I18n.t("goals.form.target_modes.months_of_expenses"),
           from: I18n.t("goals.form.fields.target_mode")
    fill_in I18n.t("goals.form.fields.target_months"), with: "6"
    check account.name

    submit = find("button", text: I18n.t("goals.form.create"))
    assert_equal "false", submit["aria-disabled"],
                 "the derived target should not leave the submit button disabled"

    submit.click

    assert_text I18n.t("goals.create.success")
    goal = Goal.order(created_at: :desc).first
    assert_equal "Emergency reserve", goal.name
    assert_equal 3_000, goal.target_amount.to_d
  end

  private
    # The browser can advertise the host machine's locale before anyone is
    # signed in. Use stable form attributes for that first request; after login
    # the user's explicit locale controls the rest of this form test.
    def sign_in_without_localized_labels(user)
      visit new_session_path
      within %(form[action='#{sessions_path}']) do
        find("input[name='email']").set(user.email)
        find("input[name='password']").set(user_password_test)
        find("button[type='submit']").click
      end

      find("h1", text: "Welcome back, #{user.first_name}")
    end
end

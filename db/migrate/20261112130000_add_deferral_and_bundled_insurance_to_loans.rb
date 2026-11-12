# Terms many European consumer loans carry and the schedule could not express:
#
#   first_payment_date    when the first instalment falls, when that is not one
#                         month after drawdown. The broken first period accrues
#                         on its actual days.
#   interest_only_months  opening instalments that pay interest (and insurance)
#                         but repay no principal -- a partial deferral.
#   insurance_included    the contracted instalment is level INCLUDING a
#                         decreasing insurance premium, so the principal and
#                         interest part grows as the premium falls.
class AddDeferralAndBundledInsuranceToLoans < ActiveRecord::Migration[8.1]
  def change
    add_column :loans, :first_payment_date, :date
    add_column :loans, :interest_only_months, :integer, default: 0, null: false
    add_column :loans, :insurance_included, :boolean, default: false, null: false

    add_check_constraint :loans,
      "interest_only_months >= 0",
      name: "chk_loans_interest_only_months_non_negative"
  end
end

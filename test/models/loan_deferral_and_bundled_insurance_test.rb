require "test_helper"

# A French consumer loan as its lender's own amortisation table prints it:
# 15,000 at 6.10%, drawn down on the 4th, 61 instalments on the 15th of which
# the first is an 11-day interest-only stub, and a level 302.69 instalment that
# includes a decreasing premium of 1.6968% a year on the outstanding balance.
class LoanDeferralAndBundledInsuranceTest < ActiveSupport::TestCase
  setup do
    @loan = build_loan(
      start_date: Date.new(2025, 11, 4), first_payment_date: Date.new(2025, 11, 15),
      term_months: 61, interest_only_months: 1,
      insurance_rate: BigDecimal("1.6968"), insurance_included: true
    )
  end

  test "the interest-only stub accrues interest and premium on its actual days" do
    row = row_for(1)

    assert_equal Date.new(2025, 11, 15), row[:date]
    assert_equal [ 0, BigDecimal("27.58"), BigDecimal("7.67") ], row.values_at(:principal, :interest, :insurance)
    assert_equal BigDecimal("15000"), @loan.amortization_schedule.payments.first.ending_balance.amount
  end

  test "the instalment stays level with the premium inside it" do
    assert_equal [ BigDecimal("205.23"), BigDecimal("76.25"), BigDecimal("21.21") ], row_for(2).values_at(:principal, :interest, :insurance)
    assert_equal [ BigDecimal("220.39"), BigDecimal("64.39"), BigDecimal("17.91") ], row_for(13).values_at(:principal, :interest, :insurance)
    assert_equal [ BigDecimal("300.74"), BigDecimal("1.53"), BigDecimal("0.43") ], row_for(61).values_at(:principal, :interest, :insurance)

    totals = (2..60).map { |number| row_for(number)[:total] }.uniq
    assert_equal [ BigDecimal("302.69") ], totals
    assert_equal BigDecimal("302.69"), @loan.monthly_payment.amount
  end

  test "the life totals match the lender's table" do
    schedule = @loan.amortization_schedule

    assert_equal 61, schedule.payments.size
    assert_equal Date.new(2030, 11, 15), schedule.payoff_date
    assert_equal BigDecimal("2500.98"), schedule.total_interest.amount
    assert_equal BigDecimal("695.68"), @loan.total_insurance.amount
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
  end

  test "the instalment in force is the one due next, counted from the first payment date" do
    assert_equal 1, @loan.payment_breakdown(as_of: Date.new(2025, 11, 10))[:number]
    assert_equal 2, @loan.payment_breakdown(as_of: Date.new(2025, 11, 20))[:number]
    assert_equal 13, @loan.payment_breakdown(as_of: Date.new(2026, 11, 12))[:number]
  end

  test "a loan without these terms keeps its level payment and dates" do
    plain = build_loan(start_date: Date.new(2025, 10, 15), term_months: 60)
    schedule = plain.amortization_schedule

    assert_equal Date.new(2025, 11, 15), schedule.payments.first.date
    assert_equal [ BigDecimal("290.69") ], schedule.payments.first(59).map { |payment| payment.payment.amount }.uniq
    assert_nil schedule.period_fraction_for(1)
  end

  test "interest-only months must leave a month to repay in" do
    @loan.interest_only_months = 61

    assert_not @loan.valid?
    assert @loan.errors[:interest_only_months].any?
  end

  test "the first payment cannot precede the drawdown" do
    @loan.first_payment_date = Date.new(2025, 11, 1)

    assert_not @loan.valid?
    assert @loan.errors[:first_payment_date].any?
  end

  private
    def build_loan(**attributes)
      Account.create!(
        family: families(:dylan_family),
        name: "Auto loan #{SecureRandom.hex(3)}",
        balance: 15_000,
        currency: "EUR",
        accountable: Loan.create!(subtype: "auto", interest_rate: BigDecimal("6.1"), rate_type: "fixed", **attributes)
      ).loan
    end

    def row_for(number)
      breakdown = @loan.payment_breakdown(payment_number: number)
      {
        date: breakdown[:date],
        principal: breakdown[:principal].amount,
        interest: breakdown[:interest].amount,
        insurance: breakdown[:insurance].amount,
        total: breakdown[:total].amount
      }
    end
end

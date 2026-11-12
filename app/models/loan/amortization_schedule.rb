# Builds a constant-payment ("French") amortisation schedule for a loan.
#
# Each period charges interest on the outstanding principal and applies the
# remainder of the level payment to principal, so the principal/interest split
# shifts over the life of the loan. This is the standard system for European
# mortgages and for most US fixed-rate loans.
#
# All arithmetic runs in BigDecimal and every payment is rounded to the
# currency's precision, exactly as a lender's own table does. The final payment
# absorbs whatever rounding residue is left so the balance lands on zero.
#
# The period-by-period walk itself lives in Loan::Simulator. This class owns
# what a *schedule* is -- the dates, the term, and the presentation of a run as
# Payment records -- and nothing about how interest accrues.
class Loan::AmortizationSchedule
  Payment = Data.define(:number, :date, :payment, :principal, :interest, :ending_balance)

  MONTHS_PER_YEAR = 12

  attr_reader :principal, :annual_rate, :term_months, :start_date, :currency, :first_payment_date,
              :interest_only_months

  class << self
    # Returns a schedule for the loan, or nil when the loan isn't amortizable
    # (missing rate/term/principal).
    def for(loan)
      return nil unless loan.amortizable?

      new(
        principal: loan.original_balance.amount,
        annual_rate: loan.interest_rate,
        term_months: loan.term_months,
        start_date: loan.origination_date,
        currency: loan.account.currency,
        rate_resolver: (Loan::RateResolver.for(loan) if loan.variable_rate_type?),
        day_count_convention: loan.day_count_convention,
        first_payment_date: loan.first_payment_date,
        interest_only_months: loan.interest_only_months,
        included_insurance_rate: (loan.insurance_rate if loan.insurance_included? && loan.insurance_rate&.positive?)
      )
    end
  end

  # `rate_resolver` is how a variable loan's recorded rate changes reach the
  # simulator. Omitted, the schedule runs at one rate for its whole life, which
  # is what a fixed loan does.
  #
  # `first_payment_date` moves the instalments off the drawdown's day of the
  # month; `interest_only_months` opens the term with instalments that repay
  # no principal; `included_insurance_rate` (annual, in percent) makes the
  # instalment level INCLUDING a premium on the outstanding balance, so each
  # row's `payment` is that level figure less the period's premium.
  def initialize(principal:, annual_rate:, term_months:, start_date:, currency:, rate_resolver: nil,
                 day_count_convention: Loan::Simulator::DEFAULT_DAY_COUNT_CONVENTION,
                 first_payment_date: nil, interest_only_months: 0, included_insurance_rate: nil)
    @currency = currency
    # Rounded to the currency at the door. A balance carrying more fractional
    # units than the currency has -- `first_valuation_amount` is decimal(19,4)
    # against two-decimal USD -- otherwise loses its residue in the first
    # period's rounding, and the principal portions then sum to less than the
    # loan. A schedule is denominated in its currency; sub-unit precision in
    # the opening balance is not a thing it can represent.
    @principal = BigDecimal(principal.to_s).round(currency_precision)
    @annual_rate = BigDecimal(annual_rate.to_s)
    @term_months = term_months.to_i
    @start_date = start_date
    @rate_resolver = rate_resolver
    @day_count_convention = day_count_convention
    @first_payment_date = first_payment_date
    @interest_only_months = interest_only_months.to_i
    @included_insurance_rate = BigDecimal(included_insurance_rate.to_s) if included_insurance_rate
  end

  # True when the first period is not one calendar month, so it accrues on
  # its actual days.
  def prorated_first_period?
    first_payment_date.present? && (start_date >> 1) != first_payment_date
  end

  # The share of a year a payment's period covers when it is prorated, nil
  # for a whole month. A premium charged alongside the interest covers the
  # same days.
  def period_fraction_for(number)
    simulation.payments.find { |row| row[:payment_number] == number }&.dig(:period_fraction)
  end

  # What the borrower pays each month once repayment starts, premium included
  # when the contract bundles it. See #periodic_payment for the part that
  # repays the loan.
  def level_instalment
    row = first_amortising_payment
    return money(0) if row.nil?
    return row.payment unless @included_insurance_rate

    row.payment + money(included_premium(row.ending_balance.amount + row.principal.amount))
  end

  # True when this schedule re-amortises part-way through, i.e. the repayment
  # is re-sized at some payment after the first. Views use it to decide whether
  # "the monthly payment" is a meaningful thing to say. Asked of the run rather
  # than of the recorded changes: a change to the same rate, or one effective
  # on the first payment, is an event that moves nothing in-term, and a
  # constant payment must not be labelled an opening one.
  def re_amortising?
    return false unless @rate_resolver
    return false unless schedulable?

    simulation.payments.each_cons(2).any? { |previous, current| previous[:sizing_rate] != current[:sizing_rate] }
  end

  # Every scheduled payment, oldest first. Empty when there is nothing to
  # amortise; shorter than the term when rounding clears the balance early.
  def payments
    @payments ||= simulation.payments.map do |row|
      Payment.new(
        number: row[:payment_number],
        date: row[:payment_date],
        payment: money(row[:payment_amount]),
        principal: money(row[:principal_payment]),
        interest: money(row[:interest_payment]),
        ending_balance: money(row[:ending_balance])
      )
    end
  end

  # The level payment the schedule opens with. The last payment can differ by
  # a few cents, and on a re-amortising loan every payment after a rate change
  # differs too -- read them off #payments when the exact figures matter, and
  # see #re_amortising? before presenting this as "the" monthly payment.
  def periodic_payment
    # Read off the first simulated payment rather than re-deriving it from the
    # base rate. A rate change effective ON the first payment date already
    # sizes that payment, and re-deriving would quote the rate the loan was
    # written at for a payment the borrower will never make. For a fixed loan
    # the two are the same number.
    #
    # Interest-only instalments are skipped: the repayment is what the loan
    # asks for once it starts repaying.
    first_amortising_payment&.payment || money(0)
  end

  # What the loan costs in interest over its whole life. Sits slightly above
  # the naive periodic_payment * term figure because interest is rounded to
  # the currency's precision every period.
  def total_interest
    money(simulation.total_interest)
  end

  # Principal plus total_interest -- everything the borrower pays.
  def total_paid
    money(payments.sum(BigDecimal("0")) { |payment| payment.payment.amount })
  end

  # The date of the final payment, or nil when there's nothing to amortise.
  def payoff_date
    payments.last&.date
  end

  # The scheduled payment falling in the same calendar month as `date`, if any.
  # Callers use this to reconcile a real bank payment against the schedule.
  def payment_for(date)
    payments.find { |payment| payment.date.year == date.year && payment.date.month == date.month }
  end

  # The repayment in force on `as_of`: the next scheduled payment on or after
  # it, sized at every rate change recorded before that payment. A variable
  # loan has no single monthly payment, but it always has this one. Nil once
  # the schedule has run out.
  def payment_in_force(as_of)
    payments.find { |payment| payment.date >= as_of }&.payment
  end

  private
    # One payment per month of the term, stepping from origination. `>>` gives
    # the calendar-correct answer at month ends: 31 January plus one month is
    # 28 February, not 3 March.
    def payment_schedule
      @payment_schedule ||=
        if first_payment_date
          (0...term_months).map { |offset| first_payment_date >> offset }
        else
          (1..term_months).map { |number| start_date >> number }
        end
    end

    def first_amortising_payment
      payments[interest_only_months.clamp(0, [ payments.size - 1, 0 ].max)]
    end

    # Whether the plain level-payment walk is not enough: a deferral or a
    # bundled premium makes the repayment a per-period figure.
    def contracted_repayment_varies?
      interest_only_months.positive? || @included_insurance_rate.present?
    end

    def included_monthly_insurance_rate
      @included_monthly_insurance_rate ||=
        @included_insurance_rate ? @included_insurance_rate / (100 * MONTHS_PER_YEAR) : BigDecimal("0")
    end

    def included_premium(balance)
      (balance * included_monthly_insurance_rate).round(currency_precision)
    end

    # The repayment the contract asks for in one period. Interest only during
    # the deferral; afterwards the level instalment -- sized once on the
    # combined interest and premium rate, and again if the rate moves -- less
    # the period's premium.
    def contracted_repayment(index:, balance:, sizing_rate:, remaining_payments:, interest:, **)
      return interest if index < interest_only_months

      if @level_instalment_amount.nil? || @level_instalment_rate != sizing_rate
        @level_instalment_rate = sizing_rate
        @level_instalment_amount = Loan::AmortizationMath.level_payment(
          balance: balance,
          monthly_rate: sizing_rate + included_monthly_insurance_rate,
          remaining_payments: remaining_payments,
          currency_precision: currency_precision
        )
      end

      @level_instalment_amount - included_premium(balance)
    end

    # The simulator refuses an empty schedule rather than inventing a
    # degenerate run, so a loan with nothing to amortise is answered here.
    def simulation
      @simulation ||= if schedulable?
        Loan::Simulator.new(
          starting_balance: principal,
          accrual_start_date: start_date,
          payment_schedule: payment_schedule,
          accrual_rate_for: @rate_resolver ? @rate_resolver.method(:accrual_rate_for) : ->(_date) { annual_rate },
          re_amortisation_events: @rate_resolver&.method(:re_amortisation_events),
          currency_precision: currency_precision,
          day_count_convention: @day_count_convention,
          prorated_first_period: prorated_first_period?,
          **(contracted_repayment_varies? ? { payment_strategy: :scheduled, payment_amount: method(:contracted_repayment) } : {})
        ).run
      else
        Loan::SimulationResult.new(payments: [], currency_precision: currency_precision)
      end
    end

    def schedulable?
      term_months.positive? && principal.positive?
    end

    def currency_precision
      @currency_precision ||= Money::Currency.new(currency).default_precision || 2
    end

    def money(value)
      Money.new(value, currency)
    end
end

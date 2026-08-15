module Analysis
  class Cashflow
    PERIOD_TYPES = %w[monthly quarterly yearly].freeze
    DEFAULT_PERIOD_TYPE = "monthly"

    attr_reader :period_type, :anchor_date, :period, :previous_period

    def initialize(family:, user:, period_type: nil, anchor_date: nil)
      @family = family
      @user = user
      @period_type = normalize_period_type(period_type)
      @anchor_date = normalize_anchor_date(anchor_date)
      @period = build_period(@anchor_date)
      @previous_period = build_previous_period
      @income_statement = family.income_statement(user: user)
    end

    def summary
      @summary ||= begin
        income = money(current_income_totals.total)
        expense = money(current_expense_totals.total)
        previous_income = money(previous_income_totals.total)
        previous_expense = money(previous_expense_totals.total)
        net = income - expense
        previous_net = previous_income - previous_expense
        savings_rate = savings_rate_for(income, net)
        previous_savings_rate = savings_rate_for(previous_income, previous_net)
        savings_rate_change = if savings_rate && previous_savings_rate
          (savings_rate - previous_savings_rate).round(1)
        end

        {
          income: income,
          expense: expense,
          net: net,
          savings_rate: savings_rate,
          income_change: percentage_change(previous_income.amount, income.amount),
          expense_change: percentage_change(previous_expense.amount, expense.amount),
          net_change: percentage_change(previous_net.amount, net.amount),
          savings_rate_change: savings_rate_change
        }
      end
    end

    def bars
      @bars ||= bar_ranges.map do |range|
        bucket_period = Period.custom(start_date: range[:start_date], end_date: range[:end_date])
        totals = @income_statement.totals_for(bucket_period)

        {
          date: range[:start_date].iso8601,
          label: bar_label(range),
          short_label: bar_short_label(range),
          income: totals.income_money.amount.to_f.round(2),
          expense: totals.expense_money.amount.to_f.round(2),
          highlighted: range[:end_date] == Date.current && period.end_date == Date.current,
          partial: range[:partial]
        }
      end
    end

    def expense_categories
      @expense_categories ||= begin
        previous_by_category = previous_net_totals.net_expense_categories.index_by do |category_total|
          category_key(category_total.category)
        end

        current_net_totals.net_expense_categories
          .reject { |category_total| category_total.total.zero? }
          .sort_by { |category_total| -category_total.total }
          .map do |category_total|
            category = category_total.category
            key = category_key(category)
            previous_total = previous_by_category[key]&.total || 0

            {
              id: key,
              name: category.name,
              display_name: category.display_name,
              amount: money(category_total.total),
              amount_value: category_total.total.to_f.round(2),
              previous_amount: money(previous_total),
              percentage: category_total.weight.round(1),
              change: percentage_change(previous_total, category_total.total),
              new_category: previous_total.zero? && category_total.total.positive?,
              color: category.color.presence || Category::UNCATEGORIZED_COLOR,
              icon: category.lucide_icon,
              clickable: !category.other_investments?
            }
          end
      end
    end

    def expense_segments
      expense_categories.map do |category|
        category.slice(:id, :name, :color).merge(amount: category[:amount_value])
      end
    end

    def expense_total
      @expense_total ||= money(current_net_totals.total_net_expense)
    end

    def period_label
      case period_type
      when "monthly"
        I18n.l(full_period_start, format: :month_year).capitalize
      when "quarterly"
        I18n.t(
          "analyses.show.period_labels.quarterly",
          quarter: ((full_period_start.month - 1) / 3) + 1,
          year: full_period_start.year
        )
      when "yearly"
        full_period_start.year.to_s
      end
    end

    def previous_anchor_date
      shift_date(full_period_start, -1)
    end

    def next_anchor_date
      shift_date(full_period_start, 1)
    end

    def latest_period?
      next_anchor_date > Date.current
    end

    def has_cashflow?
      summary[:income].positive? || summary[:expense].positive?
    end

    private
      attr_reader :family, :user, :income_statement

      def normalize_period_type(value)
        value = value.to_s
        PERIOD_TYPES.include?(value) ? value : DEFAULT_PERIOD_TYPE
      end

      def normalize_anchor_date(value)
        date = case value
        when Time, DateTime
          value.to_date
        when Date
          value
        else
          Date.iso8601(value.to_s)
        end

        [ date, Date.current ].min
      rescue Date::Error, TypeError
        Date.current
      end

      def build_period(date)
        start_date, end_date = full_period_bounds(date)
        Period.custom(start_date: start_date, end_date: [ end_date, Date.current ].min)
      end

      def build_previous_period
        previous_start, previous_full_end = full_period_bounds(shift_date(full_period_start, -1))
        previous_end = [ shift_date(period.end_date, -1), previous_full_end ].min

        Period.custom(start_date: previous_start, end_date: previous_end)
      end

      def full_period_bounds(date)
        case period_type
        when "monthly"
          [ date.beginning_of_month.to_date, date.end_of_month.to_date ]
        when "quarterly"
          [ date.beginning_of_quarter.to_date, date.end_of_quarter.to_date ]
        when "yearly"
          [ date.beginning_of_year.to_date, date.end_of_year.to_date ]
        end
      end

      def full_period_start
        @full_period_start ||= full_period_bounds(anchor_date).first
      end

      def full_period_end
        @full_period_end ||= full_period_bounds(anchor_date).last
      end

      def shift_date(date, direction)
        case period_type
        when "monthly"
          date.advance(months: direction)
        when "quarterly"
          date.advance(months: direction * 3)
        when "yearly"
          date.advance(years: direction)
        end
      end

      def current_income_totals
        @current_income_totals ||= income_statement.income_totals(period: period)
      end

      def current_expense_totals
        @current_expense_totals ||= income_statement.expense_totals(period: period)
      end

      def previous_income_totals
        @previous_income_totals ||= income_statement.income_totals(period: previous_period)
      end

      def previous_expense_totals
        @previous_expense_totals ||= income_statement.expense_totals(period: previous_period)
      end

      def current_net_totals
        @current_net_totals ||= income_statement.net_category_totals(period: period)
      end

      def previous_net_totals
        @previous_net_totals ||= income_statement.net_category_totals(period: previous_period)
      end

      def money(amount)
        Money.new(amount, family.currency)
      end

      def savings_rate_for(income, net)
        return nil if income.zero?

        (net.amount / income.amount * 100).round(1)
      end

      def percentage_change(previous_value, current_value)
        previous_value = previous_value.to_d
        current_value = current_value.to_d
        return nil if previous_value.zero?

        ((current_value - previous_value) / previous_value.abs * 100).round(1)
      end

      def category_key(category)
        if category.uncategorized?
          "uncategorized"
        elsif category.other_investments?
          "other_investments"
        else
          category.id.to_s
        end
      end

      def bar_ranges
        @bar_ranges ||= period_type == "monthly" ? weekly_ranges : monthly_ranges
      end

      def weekly_ranges
        ranges = []
        start_date = full_period_start

        while start_date <= period.end_date
          natural_end = [ start_date + 6.days, full_period_end ].min
          end_date = [ natural_end, period.end_date ].min
          ranges << {
            start_date: start_date,
            end_date: end_date,
            partial: end_date < natural_end
          }
          start_date += 7.days
        end

        ranges
      end

      def monthly_ranges
        ranges = []
        start_date = full_period_start.beginning_of_month.to_date

        while start_date <= period.end_date
          natural_end = [ start_date.end_of_month.to_date, full_period_end ].min
          end_date = [ natural_end, period.end_date ].min
          ranges << {
            start_date: start_date,
            end_date: end_date,
            partial: end_date < natural_end
          }
          start_date = start_date.next_month
        end

        ranges
      end

      def bar_label(range)
        return I18n.l(range[:start_date], format: "%b") unless period_type == "monthly"

        if range[:start_date] == range[:end_date]
          range[:start_date].day.to_s
        else
          I18n.t(
            "analyses.show.chart.day_range",
            from: range[:start_date].day,
            to: range[:end_date].day
          )
        end
      end

      def bar_short_label(range)
        bar_label(range)
      end
  end
end

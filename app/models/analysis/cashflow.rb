require "digest/md5"

module Analysis
  class Cashflow
    PERIOD_TYPES = %w[monthly quarterly yearly].freeze
    DEFAULT_PERIOD_TYPE = "monthly"
    SPENDING_PARENT_NAMES = [
      "Dépenses courantes",
      "Depenses courantes",
      "Current expenses",
      "Everyday expenses"
    ].freeze

    attr_reader :period_type, :anchor_date, :period, :previous_period, :cashflow_year

    def initialize(family:, user:, period_type: nil, anchor_date: nil, cashflow_year: nil)
      @family = family
      @user = user
      @period_type = normalize_period_type(period_type)
      @anchor_date = normalize_anchor_date(anchor_date)
      @cashflow_year = normalize_cashflow_year(cashflow_year)
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

    def checking_accounts
      @checking_accounts ||= income_statement
        .eligible_accounts
        .where(accountable_type: "Depository")
        .includes(:accountable)
        .select { |account| (account.subtype.presence || Depository::DEFAULT_SUBTYPE) == "checking" }
        .sort_by { |account| account.name.to_s.downcase }
    end

    def annual_account_legend
      @annual_account_legend ||= checking_accounts.each_with_index.map do |account, index|
        {
          id: account.id.to_s,
          name: account.name,
          color: Category::COLORS[index % Category::COLORS.length]
        }
      end
    end

    def annual_period
      @annual_period ||= begin
        start_date = Date.new(cashflow_year, 1, 1)
        end_date = [ Date.new(cashflow_year, 12, 31), Date.current ].min
        Period.custom(start_date: start_date, end_date: end_date)
      end
    end

    def annual_bars
      @annual_bars ||= begin
        if checking_account_ids.empty?
          []
        else
          annual_bar_ranges.map do |range|
            accounts = annual_account_legend.map do |account|
              totals = annual_monthly_account_totals[[ range[:start_date], account[:id] ]]

              account.merge(
                income: (totals&.income_money&.amount || 0).to_d,
                expense: (totals&.expense_money&.amount || 0).to_d
              )
            end
            income = accounts.sum { |account| account[:income] }
            expense = accounts.sum { |account| account[:expense] }
            accounts.each do |account|
              account[:income_percentage] = percentage_share(account[:income], income)
              account[:expense_percentage] = percentage_share(account[:expense], expense)
              account[:income] = account[:income].to_f.round(2)
              account[:expense] = account[:expense].to_f.round(2)
            end

            {
              date: range[:start_date].iso8601,
              end_date: range[:end_date].iso8601,
              label: I18n.l(range[:start_date], format: "%b").capitalize,
              short_label: I18n.l(range[:start_date], format: "%b").capitalize,
              income: income.to_f.round(2),
              expense: expense.to_f.round(2),
              accounts: accounts,
              highlighted: range[:end_date] == Date.current,
              partial: range[:partial]
            }
          end
        end
      end
    end

    def annual_summary
      @annual_summary ||= begin
        current = totals_for_checking_accounts(annual_period)
        previous = totals_for_checking_accounts(previous_annual_period)
        net = current[:income] - current[:expense]
        previous_net = previous[:income] - previous[:expense]

        {
          income: current[:income],
          expense: current[:expense],
          net: net,
          savings_rate: savings_rate_for(current[:income], net),
          income_change: percentage_change(previous[:income].amount, current[:income].amount),
          expense_change: percentage_change(previous[:expense].amount, current[:expense].amount),
          net_change: percentage_change(previous_net.amount, net.amount)
        }
      end
    end

    def annual_account_breakdown
      @annual_account_breakdown ||= begin
        legend_by_id = annual_account_legend.index_by { |account| account[:id] }
        rows = checking_accounts.map do |account|
          totals = income_statement.totals_for(annual_period, account_ids: [ account.id ])
          net = totals.income_money - totals.expense_money
          metadata = legend_by_id.fetch(account.id.to_s)

          {
            id: account.id.to_s,
            name: account.name,
            color: metadata[:color],
            income: totals.income_money,
            expense: totals.expense_money,
            expense_value: totals.expense_money.amount.to_f.round(2),
            net: net
          }
        end

        total_expense = rows.sum { |row| row[:expense].amount }
        rows.each do |row|
          row[:percentage] = total_expense.zero? ? 0 : (row[:expense].amount / total_expense * 100).round(1)
        end

        rows.sort_by { |row| -row[:expense].amount }
      end
    end

    def annual_account_segments
      annual_account_breakdown.filter_map do |account|
        next unless account[:expense].positive?

        account.slice(:id, :name, :color).merge(amount: account[:expense_value])
      end
    end

    def cumulative_net_series
      @cumulative_net_series ||= begin
        running_total = 0.to_d
        previous_value = money(0)
        values = [
          Series::Value.new(
            date: annual_period.start_date,
            date_formatted: I18n.l(annual_period.start_date, format: :long),
            value: previous_value,
            trend: Trend.new(current: previous_value, previous: previous_value)
          )
        ]

        annual_bars.each do |bar|
          running_total += bar[:income].to_d - bar[:expense].to_d
          current_value = money(running_total)
          date = Date.iso8601(bar[:end_date])

          values << Series::Value.new(
            date: date,
            date_formatted: I18n.l(date, format: :long),
            value: current_value,
            trend: Trend.new(current: current_value, previous: previous_value)
          )
          previous_value = current_value
        end

        Series.new(
          start_date: annual_period.start_date,
          end_date: annual_period.end_date,
          interval: "1 month",
          values: values
        )
      end
    end

    def annual_highlights
      @annual_highlights ||= begin
        highest_month = annual_bars
          .select { |bar| bar[:expense].positive? }
          .max_by { |bar| bar[:expense] }
        highest_account = annual_account_breakdown
          .select { |account| account[:expense].positive? }
          .max_by { |account| account[:expense].amount }
        elapsed_months = annual_bars.size
        average_expense = if elapsed_months.zero?
          money(0)
        else
          money(annual_summary[:expense].amount / elapsed_months)
        end

        {
          average_monthly_expense: average_expense,
          highest_expense_month: highest_month,
          highest_expense_account: highest_account,
          expense_change: annual_summary[:expense_change]
        }
      end
    end

    def expense_category_parent
      return @expense_category_parent if defined?(@expense_category_parent)

      @expense_category_parent = begin
        roots = family.categories.roots.includes(:subcategories).to_a
        roots.find do |category|
          normalized_spending_parent_names.include?(normalize_category_name(category.name))
        end
      end
    end

    def expense_categories
      @expense_categories ||= if expense_category_parent
        build_subcategory_expense_categories(expense_category_parent)
      else
        build_root_expense_categories
      end
    end

    def expense_segments
      expense_categories.map do |category|
        category.slice(:id, :name, :color).merge(amount: category[:amount_value])
      end
    end

    def expense_total
      @expense_total ||= money(expense_categories.sum { |category| category[:amount].amount })
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

    def previous_cashflow_year
      cashflow_year - 1
    end

    def next_cashflow_year
      cashflow_year + 1
    end

    def latest_cashflow_year?
      cashflow_year >= Date.current.year
    end

    def has_annual_cashflow?
      annual_summary[:income].positive? || annual_summary[:expense].positive?
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

      def normalize_cashflow_year(value)
        year = Integer(value || Date.current.year)
        year.clamp(1900, Date.current.year)
      rescue ArgumentError, TypeError
        Date.current.year
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

      def checking_account_ids
        @checking_account_ids ||= checking_accounts.map(&:id)
      end

      def previous_annual_period
        @previous_annual_period ||= begin
          start_date = Date.new(cashflow_year - 1, 1, 1)
          end_date = if latest_cashflow_year?
            annual_period.end_date.prev_year
          else
            Date.new(cashflow_year - 1, 12, 31)
          end
          Period.custom(start_date: start_date, end_date: end_date)
        end
      end

      def totals_for_checking_accounts(target_period)
        return { income: money(0), expense: money(0) } if checking_account_ids.empty?

        totals = income_statement.totals_for(target_period, account_ids: checking_account_ids)
        { income: totals.income_money, expense: totals.expense_money }
      end

      def annual_bar_ranges
        @annual_bar_ranges ||= begin
          ranges = []
          start_date = annual_period.start_date

          while start_date <= annual_period.end_date
            natural_end = start_date.end_of_month.to_date
            end_date = [ natural_end, annual_period.end_date ].min
            ranges << {
              start_date: start_date,
              end_date: end_date,
              partial: end_date < natural_end
            }
            start_date = start_date.next_month
          end

          ranges
        end
      end

      def annual_monthly_account_totals
        @annual_monthly_account_totals ||= income_statement
          .monthly_totals_by_account(period: annual_period, account_ids: checking_account_ids)
          .index_by { |total| [ total.period_start, total.account_id ] }
      end

      def build_subcategory_expense_categories(parent)
        children = parent.subcategories.to_a
        rows = children.filter_map do |category|
          current_total = net_total_for_category(category, current_expense_totals, current_income_totals)
          next unless current_total.positive?

          {
            category: category,
            id: category.id.to_s,
            name: category.name,
            display_name: category.display_name,
            icon: category.lucide_icon,
            current_total: current_total,
            previous_total: net_total_for_category(category, previous_expense_totals, previous_income_totals),
            clickable: true
          }
        end

        direct_current = direct_parent_net_total(parent, children, current_expense_totals, current_income_totals)
        if direct_current.positive?
          rows << {
            category: parent,
            id: "#{parent.id}-direct",
            name: parent.name,
            display_name: I18n.t("analyses.show.categories.without_subcategory"),
            icon: parent.lucide_icon,
            current_total: direct_current,
            previous_total: direct_parent_net_total(parent, children, previous_expense_totals, previous_income_totals),
            clickable: true
          }
        end

        build_expense_category_rows(rows, use_analysis_palette: true)
      end

      def build_root_expense_categories
        previous_by_category = previous_net_totals.net_expense_categories.index_by do |category_total|
          category_key(category_total.category)
        end

        rows = current_net_totals.net_expense_categories.filter_map do |category_total|
          next if category_total.total.zero?

          category = category_total.category
          key = category_key(category)
          {
            category: category,
            id: key,
            name: category.name,
            display_name: category.display_name,
            icon: category.lucide_icon,
            current_total: category_total.total,
            previous_total: previous_by_category[key]&.total || 0,
            color: category.color.presence || Category::UNCATEGORIZED_COLOR,
            clickable: !category.other_investments?
          }
        end

        build_expense_category_rows(rows, use_analysis_palette: false)
      end

      def build_expense_category_rows(rows, use_analysis_palette:)
        total = rows.sum { |row| row[:current_total] }

        rows.sort_by { |row| -row[:current_total] }.map do |row|
          current_total = row[:current_total]
          previous_total = row[:previous_total]
          color = if use_analysis_palette
            palette_color(row[:id])
          else
            row[:color]
          end

          row.except(:category, :current_total, :previous_total).merge(
            amount: money(current_total),
            amount_value: current_total.to_f.round(2),
            previous_amount: money(previous_total),
            percentage: total.zero? ? 0 : (current_total.to_f / total * 100).round(1),
            change: percentage_change(previous_total, current_total),
            new_category: previous_total.zero? && current_total.positive?,
            color: color
          )
        end
      end

      def net_total_for_category(category, expense_totals, income_totals)
        expense = category_total_for(expense_totals, category)
        income = category_total_for(income_totals, category)
        expense - income
      end

      def direct_parent_net_total(parent, children, expense_totals, income_totals)
        parent_expense = category_total_for(expense_totals, parent)
        children_expense = children.sum { |category| category_total_for(expense_totals, category) }
        parent_income = category_total_for(income_totals, parent)
        children_income = children.sum { |category| category_total_for(income_totals, category) }
        (parent_expense - children_expense) - (parent_income - children_income)
      end

      def category_total_for(period_total, category)
        total = period_total.category_totals.find do |category_total|
          category_total.category.id == category.id
        end&.total
        (total || 0).to_d
      end

      def normalized_spending_parent_names
        @normalized_spending_parent_names ||= SPENDING_PARENT_NAMES.map { |name| normalize_category_name(name) }
      end

      def normalize_category_name(name)
        I18n.transliterate(name.to_s).downcase.squish
      end

      def palette_color(key)
        digest = Digest::MD5.hexdigest(key.to_s).to_i(16)
        Category::COLORS[digest % Category::COLORS.length]
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

      def percentage_share(value, total)
        return 0 if total.zero?

        (value.to_d / total.to_d * 100).round(1).to_f
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
  end
end

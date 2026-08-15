class IncomeStatement::AccountMonthTotals
  def initialize(family, transactions_scope:, account_ids:, included_account_ids: nil)
    @family = family
    @transactions_scope = transactions_scope
    @account_ids = account_ids
    @included_account_ids = included_account_ids
  end

  def call
    return [] if @account_ids.empty? || @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(sanitized_query_sql).map do |row|
      Row.new(
        period_start: Date.iso8601(row["period_start"].to_s),
        account_id: row["account_id"].to_s,
        classification: row["classification"],
        total: row["total"].to_d
      )
    end
  end

  private
    Row = Data.define(:period_start, :account_id, :classification, :total)

    def sanitized_query_sql
      ActiveRecord::Base.sanitize_sql_array([ query_sql, sql_params ])
    end

    def query_sql
      <<~SQL
        SELECT
          date_trunc('month', ae.date)::date AS period_start,
          ae.account_id,
          CASE
            WHEN at.kind IN ('investment_contribution', 'loan_payment') THEN 'expense'
            WHEN ae.amount < 0 THEN 'income'
            ELSE 'expense'
          END AS classification,
          ABS(SUM(
            CASE
              WHEN at.kind IN ('investment_contribution', 'loan_payment')
                THEN ABS(ae.amount * COALESCE(er.rate, 1))
              ELSE ae.amount * COALESCE(er.rate, 1)
            END
          )) AS total
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          AND (
            at.investment_activity_label IS NULL
            OR at.investment_activity_label NOT IN ('Transfer', 'Sweep In', 'Sweep Out', 'Exchange')
          )
          AND ae.excluded = false
          AND ae.account_id IN (:account_ids)
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY
          date_trunc('month', ae.date)::date,
          ae.account_id,
          CASE
            WHEN at.kind IN ('investment_contribution', 'loan_payment') THEN 'expense'
            WHEN ae.amount < 0 THEN 'income'
            ELSE 'expense'
          END
      SQL
    end

    def sql_params
      params = {
        target_currency: @family.currency,
        family_id: @family.id,
        account_ids: @account_ids
      }

      tax_advantaged_ids = @family.tax_advantaged_account_ids
      params[:tax_advantaged_account_ids] = tax_advantaged_ids if tax_advantaged_ids.present?
      params[:included_account_ids] = @included_account_ids if @included_account_ids
      params
    end

    def budget_excluded_kinds_sql
      @budget_excluded_kinds_sql ||= Transaction::BUDGET_EXCLUDED_KINDS.map { |kind| "'#{kind}'" }.join(", ")
    end

    def exclude_tax_advantaged_sql
      ids = @family.tax_advantaged_account_ids
      return "" if ids.empty?

      "AND a.id NOT IN (:tax_advantaged_account_ids)"
    end

    def include_finance_accounts_sql
      return "" if @included_account_ids.nil?

      "AND a.id IN (:included_account_ids)"
    end
end

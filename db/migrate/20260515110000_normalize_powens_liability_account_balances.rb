class NormalizePowensLiabilityAccountBalances < ActiveRecord::Migration[7.2]
  def up
    account_ids = select_values(<<~SQL.squish)
      SELECT accounts.id
      FROM accounts
      INNER JOIN account_providers
        ON account_providers.account_id = accounts.id
      INNER JOIN powens_accounts
        ON account_providers.provider_type = 'PowensAccount'
        AND account_providers.provider_id = powens_accounts.id
      WHERE accounts.accountable_type IN ('CreditCard', 'Loan')
    SQL

    return if account_ids.empty?

    quoted_ids = account_ids.map { |id| quote(id) }.join(", ")

    execute(<<~SQL.squish)
      UPDATE accounts
      SET
        balance = ABS(balance),
        cash_balance = ABS(cash_balance),
        updated_at = CURRENT_TIMESTAMP
      WHERE id IN (#{quoted_ids})
        AND (balance < 0 OR cash_balance < 0)
    SQL

    execute(<<~SQL.squish)
      UPDATE entries
      SET
        amount = ABS(entries.amount),
        updated_at = CURRENT_TIMESTAMP
      FROM valuations
      WHERE entries.entryable_type = 'Valuation'
        AND entries.entryable_id = valuations.id
        AND valuations.kind = 'opening_anchor'
        AND entries.account_id IN (#{quoted_ids})
        AND entries.amount < 0
    SQL
  end

  def down
    # Not reversible: the provider does not expose enough metadata to infer
    # whether an existing negative liability balance was intentional.
  end
end

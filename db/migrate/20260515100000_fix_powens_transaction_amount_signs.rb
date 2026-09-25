class FixPowensTransactionAmountSigns < ActiveRecord::Migration[7.2]
  CONVENTION = "sure_expense_positive"

  def up
    execute <<~SQL.squish
      UPDATE entries
      SET amount = -amount,
          updated_at = CURRENT_TIMESTAMP
      FROM transactions
      WHERE entries.entryable_type = 'Transaction'
        AND entries.entryable_id = transactions.id
        AND entries.source = 'powens'
        AND (transactions.extra -> 'powens' ->> 'amount_convention') IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE transactions
      SET extra = jsonb_set(
        COALESCE(transactions.extra, '{}'::jsonb),
        '{powens}',
        COALESCE(transactions.extra -> 'powens', '{}'::jsonb) || jsonb_build_object('amount_convention', '#{CONVENTION}'),
        true
      )
      FROM entries
      WHERE entries.entryable_type = 'Transaction'
        AND entries.entryable_id = transactions.id
        AND entries.source = 'powens'
        AND (transactions.extra -> 'powens' ->> 'amount_convention') IS NULL
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE entries
      SET amount = -amount,
          updated_at = CURRENT_TIMESTAMP
      FROM transactions
      WHERE entries.entryable_type = 'Transaction'
        AND entries.entryable_id = transactions.id
        AND entries.source = 'powens'
        AND transactions.extra -> 'powens' ->> 'amount_convention' = '#{CONVENTION}'
    SQL

    execute <<~SQL.squish
      UPDATE transactions
      SET extra = jsonb_set(
        transactions.extra,
        '{powens}',
        (transactions.extra -> 'powens') - 'amount_convention',
        true
      )
      FROM entries
      WHERE entries.entryable_type = 'Transaction'
        AND entries.entryable_id = transactions.id
        AND entries.source = 'powens'
        AND transactions.extra -> 'powens' ->> 'amount_convention' = '#{CONVENTION}'
    SQL
  end
end

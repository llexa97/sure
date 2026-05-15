class PowensAccount::Processor
  attr_reader :powens_account, :skipped_entries

  def initialize(powens_account)
    @powens_account = powens_account
    @skipped_entries = []
  end

  def process
    return unless powens_account.current_account.present?

    process_account!
    process_transactions
  end

  private
    def process_account!
      account = powens_account.current_account
      balance = powens_account.current_balance || account.balance

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: powens_account.currency || account.currency
      )
    end

    def process_transactions
      payload = powens_account.raw_transactions_payload || []
      transactions = Array(payload).map do |tx|
        PowensAccount::Normalizer.normalize_transaction(
          tx,
          account_currency: powens_account.currency || powens_account.current_account.currency
        )
      end.compact

      adapter = Account::ProviderImportAdapter.new(powens_account.current_account)

      transactions.each do |tx|
        extra = {
          powens: {
            pending: tx[:pending],
            transaction_id: tx[:raw]["id"] || tx[:raw][:id],
            raw_value: tx[:raw]["value"] || tx[:raw][:value] || tx[:raw]["gross_value"] || tx[:raw][:gross_value],
            amount_convention: "sure_expense_positive",
            coming: tx[:pending],
            type: tx[:raw]["type"] || tx[:raw][:type]
          }
        }

        adapter.import_transaction(
          external_id: tx[:external_id],
          amount: tx[:amount],
          currency: tx[:currency] || powens_account.currency || powens_account.current_account.currency,
          date: tx[:date],
          name: tx[:name],
          notes: tx[:notes],
          source: "powens",
          extra: extra
        )
      end

      @skipped_entries.concat(adapter.skipped_entries)
    end
end

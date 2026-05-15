class PowensAccount::Processor
  attr_reader :powens_account, :skipped_entries

  def initialize(powens_account)
    @powens_account = powens_account
    @skipped_entries = []
  end

  def process
    return unless powens_account.current_account.present?

    process_account!
    if powens_account.investment?
      process_investments
    else
      process_transactions
    end
  end

  private
    def process_account!
      account = powens_account.current_account
      balance = powens_account.current_balance_for(account.accountable_type) || account.balance

      if account.accountable_type == "Investment"
        # For investment accounts, the provider balance is the total portfolio
        # valuation. Cash inside the account is tracked separately (not surfaced
        # by Powens here), so we keep cash_balance at zero and let the holdings
        # carry the value.
        account.update!(
          balance: balance,
          cash_balance: 0,
          currency: powens_account.currency || account.currency
        )
      else
        account.update!(
          balance: balance,
          cash_balance: balance,
          currency: powens_account.currency || account.currency
        )
      end
    end

    def process_investments
      resolver = PowensAccount::Investments::SecurityResolver.new
      PowensAccount::Investments::HoldingsProcessor.new(powens_account, security_resolver: resolver).process
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

class PowensAccount::Processor
  ProcessingError = Class.new(StandardError)

  attr_reader :powens_account, :skipped_entries

  def initialize(powens_account)
    @powens_account = powens_account
    @skipped_entries = []
  end

  def process
    return unless powens_account.current_account.present?

    process_account!
    process_investments if powens_account.investment?
    process_transactions
  end

  private
    def process_account!
      account = powens_account.current_account
      balance = powens_account.current_balance_for(account.accountable_type) || account.balance
      currency = powens_account.currency || account.currency
      cash_balance = account.accountable_type == "Investment" ? 0 : balance

      update_current_balance!(account, balance: balance, cash_balance: cash_balance, currency: currency)
    end

    def update_current_balance!(account, balance:, cash_balance:, currency:)
      ActiveRecord::Base.transaction do
        account.update!(cash_balance: cash_balance, currency: currency)

        result = Account::CurrentBalanceManager.new(account).set_current_balance(balance)
        raise ProcessingError, "Failed to set current balance: #{result.error}" unless result.success?
      end
    end

    def process_investments
      resolver = PowensAccount::Investments::SecurityResolver.new
      matcher = PowensAccount::Investments::SecurityMatcher.new(powens_account, security_resolver: resolver)
      PowensAccount::Investments::HoldingsProcessor.new(powens_account, security_resolver: resolver).process
      PowensAccount::Investments::TransactionsProcessor.new(powens_account, security_matcher: matcher).process
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

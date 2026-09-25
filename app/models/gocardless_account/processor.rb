class GocardlessAccount::Processor
  attr_reader :gocardless_account, :skipped_entries

  def initialize(gocardless_account)
    @gocardless_account = gocardless_account
    @skipped_entries = []
  end

  def process
    return unless gocardless_account.current_account.present?

    process_account!
    process_transactions
  end

  private
    def process_account!
      account = gocardless_account.current_account
      account.update!(
        balance: gocardless_account.current_balance || account.balance,
        cash_balance: gocardless_account.current_balance || account.cash_balance,
        currency: gocardless_account.currency || account.currency
      )
    end

    def process_transactions
      payload = (gocardless_account.raw_transactions_payload || {}).with_indifferent_access
      booked = Array(payload.dig(:transactions, :booked)).map { |tx| GocardlessAccount::Normalizer.normalize_transaction(tx, booked: true) }.compact
      pending = Array(payload.dig(:transactions, :pending)).map { |tx| GocardlessAccount::Normalizer.normalize_transaction(tx, booked: false) }.compact
      adapter = Account::ProviderImportAdapter.new(gocardless_account.current_account)

      (booked + pending).each do |tx|
        extra = {
          gocardless: {
            pending: tx[:pending],
            transaction_id: tx[:raw]["transactionId"] || tx[:raw][:transactionId],
            booking_status: tx[:pending] ? "pending" : "booked"
          }
        }
        adapter.import_transaction(
          external_id: tx[:external_id],
          amount: tx[:amount],
          currency: tx[:currency] || gocardless_account.currency || gocardless_account.current_account.currency,
          date: tx[:date],
          name: tx[:name],
          notes: tx[:notes],
          source: "gocardless",
          extra: extra
        )
      end
      @skipped_entries.concat(adapter.skipped_entries)
    end
end

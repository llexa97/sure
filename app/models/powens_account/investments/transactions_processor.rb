class PowensAccount::Investments::TransactionsProcessor
  def initialize(powens_account, security_matcher:)
    @powens_account = powens_account
    @security_matcher = security_matcher
  end

  def process
    market_orders.each do |raw_transaction|
      process_market_order(raw_transaction.with_indifferent_access)
    end
  end

  private
    attr_reader :powens_account, :security_matcher

    def process_market_order(transaction)
      normalized = normalize_market_order(transaction)
      return if normalized.nil?

      match = security_matcher.match(normalized[:name])
      if match.nil?
        Rails.logger.warn("Powens market_order skipped: no holding matched wording=#{normalized[:name].inspect} account=#{powens_account.id}")
        return
      end

      return unless remove_legacy_cash_entry!(normalized[:external_id])

      import_adapter.import_trade(
        external_id: normalized[:external_id],
        security: match.security,
        quantity: normalized[:cash_amount] / match.unit_price,
        price: match.unit_price,
        amount: normalized[:cash_amount],
        currency: match.currency || normalized[:currency],
        date: normalized[:date],
        name: normalized[:name],
        source: "powens",
        activity_label: "Buy"
      )
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Powens market_order skipped: #{e.class} #{e.message} account=#{powens_account.id}")
    end

    def normalize_market_order(transaction)
      date = transaction[:application_date].presence || transaction[:date].presence || transaction[:rdate].presence || transaction[:vdate].presence
      amount = transaction[:value].presence || transaction[:gross_value].presence
      return nil if date.blank? || amount.blank?

      provider_amount = BigDecimal(amount.to_s)
      cash_amount = provider_amount.abs
      return nil if cash_amount.zero?

      name = transaction[:wording].presence || transaction[:simplified_wording].presence || transaction[:original_wording].presence || "Powens market order"

      {
        external_id: PowensAccount::Normalizer.external_id(transaction, amount: provider_amount, date: date),
        cash_amount: cash_amount,
        currency: powens_account.currency || account.currency,
        date: Date.parse(date.to_s),
        name: name.to_s.squish.presence || "Powens market order"
      }
    rescue ArgumentError, TypeError
      nil
    end

    def remove_legacy_cash_entry!(external_id)
      entry = account.entries.find_by(external_id: external_id, source: "powens")
      return true unless entry&.transaction?

      if entry.protected_from_sync?
        Rails.logger.warn("Powens market_order skipped: legacy cash entry is protected entry=#{entry.id} account=#{account.id}")
        return false
      end

      entry.destroy!
      true
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      powens_account.current_account
    end

    def market_orders
      Array(powens_account.raw_transactions_payload).select do |transaction|
        PowensAccount::Normalizer.market_order?(transaction)
      end
    end
end

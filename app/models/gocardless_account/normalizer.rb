class GocardlessAccount::Normalizer
  BALANCE_PRIORITY = %w[closingBooked interimBooked interimAvailable expected forwardAvailable nonInvoiced openingBooked].freeze

  class << self
    def account_name(account)
      account = account.with_indifferent_access
      iban = account[:iban]
      [ account[:name].presence || account[:displayName].presence || account[:product].presence || "GoCardless Account", masked_iban(iban), account[:currency] ].compact.join(" ")
    end

    def masked_iban(iban)
      return nil if iban.blank?
      "(XXX #{iban.to_s.last(4)})"
    end

    def best_balance(balances)
      normalized = Array(balances).map { |b| normalize_balance(b) }.compact
      selected = BALANCE_PRIORITY.lazy.map { |type| normalized.find { |b| b[:type] == type } }.find(&:present?) || normalized.first
      return nil unless selected

      selected
    end

    def normalize_balance(balance)
      b = balance.with_indifferent_access
      amount_hash = b[:balanceAmount] || b[:balance_amount] || {}
      amount = amount_hash[:amount] || b[:amount]
      return nil if amount.blank?

      parsed = BigDecimal(amount.to_s)
      parsed = -parsed if b[:creditDebitIndicator].to_s.upcase == "DBIT" || b[:credit_debit_indicator].to_s.upcase == "DBIT"

      {
        type: b[:balanceType] || b[:balance_type],
        amount: parsed,
        available_amount: parsed,
        currency: amount_hash[:currency] || b[:currency]
      }
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_transaction(raw_transaction, booked:)
      tx = raw_transaction.with_indifferent_access
      date = tx[:date].presence || tx[:bookingDate].presence || tx[:bookingDateTime].presence || tx[:valueDate].presence || tx[:valueDateTime].presence
      return nil if date.blank?

      amount_hash = tx[:transactionAmount] || tx[:transaction_amount] || {}
      # raw_amount follows GoCardless/banking convention: positive = income, negative = expense.
      # App convention is the opposite, so we negate for storage.
      raw_amount = BigDecimal(amount_hash[:amount].to_s)
      amount = -raw_amount
      currency = amount_hash[:currency]
      notes = tx[:remittanceInformationUnstructured].presence || Array(tx[:remittanceInformationUnstructuredArray]).join(" ").presence || tx[:additionalInformation].presence
      payee = payee_name(tx, raw_amount) || notes || "GoCardless transaction"

      {
        external_id: external_id(tx, amount: raw_amount, date: date, booked: booked),
        amount: amount,
        currency: currency,
        date: Date.parse(date.to_s),
        name: payee.to_s.squish.presence || "GoCardless transaction",
        notes: notes,
        pending: !booked,
        raw: tx.to_h
      }
    rescue ArgumentError, TypeError
      nil
    end

    def external_id(tx, amount:, date:, booked:)
      provider_id = tx[:transactionId].presence || tx[:internalTransactionId].presence || tx[:entryReference].presence
      return "gocardless_#{provider_id}" if provider_id.present?

      digest_input = [ date, amount.to_s("F"), tx.dig(:transactionAmount, :currency), tx[:remittanceInformationUnstructured], tx[:debtorName], tx[:creditorName], booked ].join("|")
      "gocardless_hash_#{Digest::SHA256.hexdigest(digest_input)}"
    end

    def payee_name(tx, amount)
      if amount.positive? || amount.zero?
        name = tx[:debtorName]
        account = tx[:debtorAccount]
      else
        name = tx[:creditorName]
        account = tx[:creditorAccount]
      end
      name = name.presence || tx[:debtorName].presence || tx[:creditorName].presence || tx[:remittanceInformationUnstructured].presence || tx[:additionalInformation].presence
      parts = []
      parts << name.to_s.titleize if name.present?
      iban = account.is_a?(Hash) ? account.with_indifferent_access[:iban] : nil
      parts << "(#{iban.to_s.first(4)} XXX #{iban.to_s.last(4)})" if iban.present?
      parts.join(" ").presence
    end
  end
end

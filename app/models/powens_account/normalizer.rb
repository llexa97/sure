class PowensAccount::Normalizer
  class << self
    def account_name(account)
      account = account.with_indifferent_access
      currency = currency_code(account[:currency])
      [ account[:name].presence || account[:original_name].presence || "Powens Account", masked_identifier(account[:iban] || account[:number]), currency ].compact.join(" ")
    end

    def normalize_transaction(raw_transaction, account_currency:)
      tx = raw_transaction.with_indifferent_access
      date = tx[:application_date].presence || tx[:date].presence || tx[:rdate].presence || tx[:vdate].presence
      amount = tx[:value].presence || tx[:gross_value].presence
      return nil if date.blank? || amount.blank?

      parsed_amount = BigDecimal(amount.to_s)
      name = tx[:wording].presence || tx[:simplified_wording].presence || tx[:original_wording].presence || "Powens transaction"

      {
        external_id: external_id(tx, amount: parsed_amount, date: date),
        amount: parsed_amount,
        currency: account_currency,
        date: Date.parse(date.to_s),
        name: name.to_s.squish.presence || "Powens transaction",
        notes: notes(tx, name),
        pending: ActiveModel::Type::Boolean.new.cast(tx[:coming]),
        raw: tx.to_h
      }
    rescue ArgumentError, TypeError
      nil
    end

    def external_id(tx, amount:, date:)
      provider_id = tx[:id].presence
      return "powens_#{provider_id}" if provider_id.present?

      digest_input = [
        date,
        amount.to_s("F"),
        tx[:original_wording],
        tx[:wording],
        tx[:type],
        tx[:id_account],
        tx[:coming]
      ].join("|")

      "powens_hash_#{Digest::SHA256.hexdigest(digest_input)}"
    end

    def notes(tx, display_name)
      values = [
        tx[:original_wording],
        tx[:simplified_wording],
        tx[:comment]
      ].compact.map(&:to_s).map(&:squish).reject(&:blank?).uniq

      values.reject { |value| value == display_name.to_s.squish }.join(" | ").presence
    end

    def masked_identifier(value)
      return nil if value.blank?

      "(XXX #{value.to_s.last(4)})"
    end

    def currency_code(value)
      value.is_a?(Hash) ? value.with_indifferent_access[:id] : value
    end
  end
end

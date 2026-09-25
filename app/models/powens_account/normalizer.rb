class PowensAccount::Normalizer
  class << self
    def market_order?(raw_transaction)
      raw_transaction.with_indifferent_access[:type].to_s.downcase == "market_order"
    end

    def account_name(account)
      account = account.with_indifferent_access
      currency = currency_code(account[:currency])
      [ account[:name].presence || account[:original_name].presence || "Powens Account", masked_identifier(account[:iban] || account[:number]), currency ].compact.join(" ")
    end

    def normalize_transaction(raw_transaction, account_currency:)
      tx = raw_transaction.with_indifferent_access
      return nil if market_order?(tx)

      date = tx[:application_date].presence || tx[:date].presence || tx[:rdate].presence || tx[:vdate].presence
      amount = tx[:value].presence || tx[:gross_value].presence
      return nil if date.blank? || amount.blank?

      provider_amount = BigDecimal(amount.to_s)
      normalized_amount = -provider_amount
      name = tx[:wording].presence || tx[:simplified_wording].presence || tx[:original_wording].presence || "Powens transaction"

      {
        external_id: external_id(tx, amount: provider_amount, date: date),
        amount: normalized_amount,
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

    def normalize_investment(raw_investment, account_currency:)
      inv = raw_investment.with_indifferent_access
      quantity = parse_decimal(inv[:quantity])
      unit_value = parse_decimal(inv[:unitvalue])
      valuation = parse_decimal(inv[:valuation])
      return nil if quantity.nil? || quantity.zero?
      return nil if unit_value.nil? && valuation.nil?

      unit_value ||= (valuation / quantity if quantity.nonzero?)
      amount = valuation || (unit_value * quantity)

      {
        external_id: external_investment_id(inv),
        ticker: inv[:stock_symbol].to_s.strip.presence,
        isin: inv[:code_type].to_s.upcase == "ISIN" ? inv[:code].to_s.strip.presence : nil,
        code: inv[:code].to_s.strip.presence,
        code_type: inv[:code_type].to_s.strip.presence,
        label: inv[:label].to_s.strip.presence,
        quantity: quantity,
        unit_price: parse_decimal(inv[:unitprice]),
        unit_value: unit_value,
        amount: amount,
        currency: (inv[:original_currency].is_a?(Hash) ? inv[:original_currency].with_indifferent_access[:id] : inv[:original_currency]).presence || account_currency,
        date: parse_date(inv[:vdate]) || Date.current,
        raw: inv.to_h
      }
    rescue ArgumentError, TypeError
      nil
    end

    def external_investment_id(inv)
      provider_id = inv[:id].presence
      return "powens_inv_#{provider_id}" if provider_id.present?

      digest_input = [ inv[:code], inv[:code_type], inv[:label], inv[:id_account] ].join("|")
      "powens_inv_hash_#{Digest::SHA256.hexdigest(digest_input)}"
    end

    private

      def parse_decimal(value)
        return nil if value.nil? || value.to_s.strip.empty?

        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def parse_date(value)
        return nil if value.blank?

        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end

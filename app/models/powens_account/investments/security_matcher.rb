class PowensAccount::Investments::SecurityMatcher
  Match = Struct.new(:security, :label, :normalized_label, :unit_price, :currency, keyword_init: true)

  def initialize(powens_account, security_resolver:)
    @powens_account = powens_account
    @security_resolver = security_resolver
  end

  def match(wording)
    normalized_wording = normalize_text(wording)
    return nil if normalized_wording.blank?

    prefix_match = matches.find { |candidate| normalized_wording.start_with?(candidate.normalized_label) }
    return prefix_match if prefix_match

    contains_match = matches.find { |candidate| normalized_wording.include?(candidate.normalized_label) }
    return contains_match if contains_match

    matches.first if matches.one?
  end

  private
    attr_reader :powens_account, :security_resolver

    def matches
      @matches ||= investments.filter_map do |raw_investment|
        normalized = PowensAccount::Normalizer.normalize_investment(
          raw_investment,
          account_currency: account.currency
        )
        next if normalized.nil? || normalized[:label].blank?

        resolved = security_resolver.resolve(
          ticker: normalized[:ticker],
          isin: normalized[:isin],
          name: normalized[:label]
        )
        next if resolved.security.nil?

        unit_price = normalized[:unit_price] || normalized[:unit_value]
        next if unit_price.nil? || unit_price <= 0
        normalized_label = normalize_text(normalized[:label])
        next if normalized_label.blank?

        Match.new(
          security: resolved.security,
          label: normalized[:label],
          normalized_label: normalized_label,
          unit_price: unit_price,
          currency: normalized[:currency]
        )
      end.sort_by { |candidate| -candidate.normalized_label.length }
    end

    def account
      powens_account.current_account
    end

    def investments
      payload = powens_account.raw_holdings_payload
      return [] if payload.blank?

      Array(payload.with_indifferent_access[:investments])
    end

    def normalize_text(value)
      I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]+/, " ").squish
    end
end

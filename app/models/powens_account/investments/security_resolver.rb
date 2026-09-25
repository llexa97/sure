class PowensAccount::Investments::SecurityResolver
  Result = Struct.new(:security, :reason, keyword_init: true)

  def initialize
    @cache = {}
  end

  def resolve(ticker:, isin:, name: nil)
    cache_key = [ ticker.to_s.upcase, isin.to_s.upcase ].join("|")
    return @cache[cache_key] if @cache.key?(cache_key)

    @cache[cache_key] = build_result(ticker: ticker, isin: isin, name: name)
  end

  private

    def build_result(ticker:, isin:, name:)
      lookup_symbol = ticker.presence || isin.presence
      return Result.new(security: nil, reason: "no_identifier") if lookup_symbol.blank?

      security = Security::Resolver.new(lookup_symbol).resolve
      assign_offline_metadata!(security, name: name, isin: isin) if security
      Result.new(security: security, reason: nil)
    rescue StandardError => e
      Rails.logger.warn("Powens SecurityResolver failed for ticker=#{ticker.inspect} isin=#{isin.inspect}: #{e.class} #{e.message}")
      Result.new(security: nil, reason: "resolver_error")
    end

    def assign_offline_metadata!(security, name:, isin:)
      return unless security.offline?

      updates = {}
      updates[:name] = name if name.present? && security.name.blank?
      security.update!(updates) if updates.any?
    end
end

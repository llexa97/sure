class PowensAccount::Investments::HoldingsProcessor
  def initialize(powens_account, security_resolver:)
    @powens_account = powens_account
    @security_resolver = security_resolver
  end

  def process
    investments.each do |raw_investment|
      normalized = PowensAccount::Normalizer.normalize_investment(
        raw_investment,
        account_currency: account.currency
      )
      next if normalized.nil?

      result = security_resolver.resolve(
        ticker: normalized[:ticker],
        isin: normalized[:isin],
        name: normalized[:label]
      )
      next if result.security.nil?

      import_adapter.import_holding(
        security: result.security,
        quantity: normalized[:quantity],
        amount: normalized[:amount],
        currency: normalized[:currency],
        date: normalized[:date],
        price: normalized[:unit_value],
        external_id: normalized[:external_id],
        source: "powens",
        account_provider_id: powens_account.account_provider&.id,
        delete_future_holdings: false
      )
    end
  end

  private
    attr_reader :powens_account, :security_resolver

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      powens_account.current_account
    end

    def investments
      payload = powens_account.raw_holdings_payload
      return [] if payload.blank?

      Array(payload.with_indifferent_access[:investments])
    end
end

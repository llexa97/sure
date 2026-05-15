class PowensAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :iban
    encrypts :number
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :powens_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :account_id, :name, presence: true
  validates :account_id, uniqueness: { scope: :powens_item_id }

  CASH_ACCOUNT_TYPE_MAP = {
    "checking" => { type: "Depository", subtype: "checking" },
    "card" => { type: "CreditCard", subtype: "credit_card" },
    "loan" => { type: "Loan", subtype: nil },
    "pret" => { type: "Loan", subtype: nil },
    "savings" => { type: "Depository", subtype: "savings" },
    "deposit" => { type: "Depository", subtype: "checking" },
    "market" => { type: "Depository", subtype: "money_market" }
  }.freeze

  def current_account
    account
  end

  def suggested_account_type
    normalized_type = normalized_account_type
    return "CreditCard" if normalized_type.include?("card")
    if normalized_type.include?("loan") || normalized_type.include?("mortgage") || normalized_type.include?("pret")
      return "Loan"
    end

    CASH_ACCOUNT_TYPE_MAP[normalized_type]&.dig(:type) || "Depository"
  end

  def suggested_subtype
    CASH_ACCOUNT_TYPE_MAP[normalized_account_type]&.dig(:subtype)
  end

  def current_balance_for(account_type)
    normalize_balance_for(account_type, current_balance)
  end

  def available_balance_for(account_type)
    normalize_balance_for(account_type, available_balance)
  end

  def upsert_powens_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access
    parsed_currency = parse_currency(currency_code(snapshot[:currency])) || powens_item.family.primary_currency_code || "EUR"

    update!(
      name: PowensAccount::Normalizer.account_name(snapshot),
      iban: snapshot[:iban],
      number: snapshot[:number],
      currency: parsed_currency,
      account_type: account_type_code(snapshot[:type]),
      current_balance: parse_decimal(snapshot[:balance]),
      available_balance: parse_decimal(snapshot[:balance]),
      disabled_at: parse_datetime(snapshot[:disabled]),
      deleted_at: parse_datetime(snapshot[:deleted]),
      institution_metadata: {
        name: powens_item.connector_name,
        connector_id: powens_item.connector_id,
        connector_uuid: powens_item.connector_uuid,
        color: powens_item.connector_color
      }.compact,
      raw_payload: snapshot
    )
  end

  def upsert_powens_transactions_snapshot!(transactions)
    update!(raw_transactions_payload: transactions)
  end

  private
    def currency_code(value)
      value.is_a?(Hash) ? value.with_indifferent_access[:id] : value
    end

    def account_type_code(value)
      return nil if value.blank?
      return value.with_indifferent_access[:name].presence || value.with_indifferent_access[:id] if value.is_a?(Hash)

      value
    end

    def normalized_account_type
      I18n.transliterate(account_type.to_s.downcase)
    end

    def normalize_balance_for(account_type, balance)
      return nil if balance.nil?

      %w[CreditCard Loan].include?(account_type.to_s) ? balance.abs : balance
    end

    def parse_decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_datetime(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
end

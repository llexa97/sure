class GocardlessAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :iban
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :gocardless_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :account_id, :name, presence: true
  validates :account_id, uniqueness: { scope: :gocardless_item_id }

  def current_account
    account
  end

  def upsert_gocardless_snapshot!(metadata:, details:, balances: nil)
    snapshot = details.with_indifferent_access[:account].to_h.with_indifferent_access
    metadata = metadata.to_h.with_indifferent_access
    merged = snapshot.merge(metadata.select { |_k, v| v.present? })
    selected_balance = GocardlessAccount::Normalizer.best_balance(Array(balances.to_h.with_indifferent_access[:balances]))

    update!(
      name: GocardlessAccount::Normalizer.account_name(merged),
      iban: merged[:iban],
      currency: parse_currency(merged[:currency]) || selected_balance&.dig(:currency) || gocardless_item.family.primary_currency_code || "EUR",
      account_type: merged[:cashAccountType] || merged[:cash_account_type] || merged[:product],
      current_balance: selected_balance&.dig(:amount),
      available_balance: selected_balance&.dig(:available_amount),
      institution_metadata: {
        name: gocardless_item.institution_name,
        institution_id: gocardless_item.institution_id,
        logo: gocardless_item.institution_logo,
        bic: merged.dig(:accountServicer, :bicFi) || merged.dig(:account_servicer, :bic_fi)
      }.compact,
      raw_payload: { metadata: metadata, details: snapshot, balances: balances }
    )
  end

  def upsert_gocardless_transactions_snapshot!(transactions)
    update!(raw_transactions_payload: transactions)
  end
end

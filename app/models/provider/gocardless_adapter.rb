class Provider::GocardlessAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  Provider::Factory.register("GocardlessAccount", self)

  configure do
    description <<~DESC
      Setup instructions:
      1. Use an existing GoCardless Bank Account Data account (new accounts may no longer be accepted).
      2. Create API secrets in the GoCardless Bank Account Data dashboard.
      3. Configure Secret ID and Secret Key here or via environment variables.
    DESC

    field :secret_id,
          label: "Secret ID",
          required: false,
          env_key: "GOCARDLESS_SECRET_ID",
          description: "GoCardless Bank Account Data Secret ID"

    field :secret_key,
          label: "Secret Key",
          required: false,
          secret: true,
          env_key: "GOCARDLESS_SECRET_KEY",
          description: "GoCardless Bank Account Data Secret Key"

    configured_check { get_value(:secret_id).present? && get_value(:secret_key).present? }
  end

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_gocardless?

    [ {
      key: "gocardless",
      name: "GoCardless",
      description: "Connect to your bank via GoCardless Bank Account Data",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_gocardless_item_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_gocardless_items_path(account_id: account_id)
      }
    } ]
  end

  def self.build_provider
    secret_id = config_value(:secret_id).presence || ENV["GOCARDLESS_SECRET_ID"]
    secret_key = config_value(:secret_key).presence || ENV["GOCARDLESS_SECRET_KEY"]
    return nil unless secret_id.present? && secret_key.present?

    Provider::Gocardless.new(secret_id: secret_id, secret_key: secret_key)
  end

  def provider_name
    "gocardless"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_gocardless_item_path(item)
  end

  def item
    provider_account.gocardless_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    nil
  end

  def institution_name
    provider_account.institution_metadata&.dig("name") || item&.institution_name
  end

  def institution_url
    nil
  end

  def institution_color
    nil
  end
end

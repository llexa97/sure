class Provider::PowensAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  Provider::Factory.register("PowensAccount", self)

  configure do
    description <<~DESC
      Setup instructions:
      1. Create a Powens sandbox domain in the Powens Console.
      2. Sandbox domains are usually suffixed with `-sandbox.biapi.pro`; configure the domain without `https://`.
      3. Create a client application and allow the callback URL shown by Powens during connection.
      4. Configure the domain, Client ID, and Client secret here or via environment variables.
    DESC

    field :domain,
          label: "API Domain",
          required: true,
          env_key: "POWENS_DOMAIN",
          description: "Powens API domain, e.g. your-app-sandbox or your-app-sandbox.biapi.pro"

    field :client_id,
          label: "Client ID",
          required: true,
          env_key: "POWENS_CLIENT_ID",
          description: "Powens client application ID"

    field :client_secret,
          label: "Client Secret",
          required: true,
          secret: true,
          env_key: "POWENS_CLIENT_SECRET",
          description: "Powens client application secret"

    configured_check { get_value(:domain).present? && get_value(:client_id).present? && get_value(:client_secret).present? }
  end

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_powens?

    [ {
      key: "powens",
      name: "Powens",
      description: "Connect European banks through Powens Webview.",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_powens_item_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_powens_items_path(account_id: account_id)
      }
    } ]
  end

  def self.build_provider
    domain = config_value(:domain).presence || ENV["POWENS_DOMAIN"]
    client_id = config_value(:client_id).presence || ENV["POWENS_CLIENT_ID"]
    client_secret = config_value(:client_secret).presence || ENV["POWENS_CLIENT_SECRET"]
    return nil unless domain.present? && client_id.present? && client_secret.present?

    Provider::Powens.new(domain: domain, client_id: client_id, client_secret: client_secret)
  end

  def provider_name
    "powens"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_powens_item_path(item)
  end

  def item
    provider_account.powens_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    nil
  end

  def institution_name
    provider_account.institution_metadata&.dig("name") || item&.connector_name
  end

  def institution_url
    nil
  end

  def institution_color
    provider_account.institution_metadata&.dig("color") || item&.connector_color
  end
end

module Family::PowensConnectable
  extend ActiveSupport::Concern

  included do
    has_many :powens_items, dependent: :destroy
  end

  def can_connect_powens?
    Provider::PowensAdapter.configured?
  end

  def create_powens_item!(auth_token:, user_id:, reference:, raw_payload: {})
    provider = Provider::PowensAdapter.build_provider

    powens_items.create!(
      name: "Powens Connection",
      domain: provider&.api_host || Provider::PowensAdapter.config_value(:domain).presence || ENV["POWENS_DOMAIN"],
      user_id: user_id,
      access_token: auth_token,
      reference: reference,
      raw_payload: raw_payload
    )
  end
end

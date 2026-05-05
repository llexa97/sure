module Family::GocardlessConnectable
  extend ActiveSupport::Concern

  included do
    has_many :gocardless_items, dependent: :destroy
  end

  def can_connect_gocardless?
    ENV["GOCARDLESS_ENABLED"].to_s.strip.downcase.in?(%w[1 true yes on]) && Provider::GocardlessAdapter.configured?
  end

  def create_gocardless_item!(institution:, country_code:, requisition:, reference: nil)
    gocardless_items.create!(
      name: institution[:name].presence || "GoCardless Connection",
      country_code: country_code,
      institution_id: institution[:id],
      institution_name: institution[:name],
      institution_logo: institution[:logo],
      agreement_id: requisition[:agreement],
      requisition_id: requisition[:id],
      reference: reference || requisition[:reference],
      raw_institution_payload: institution,
      raw_payload: requisition,
      access_expires_at: 90.days.from_now
    )
  end
end

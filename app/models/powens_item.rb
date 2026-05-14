class PowensItem < ApplicationRecord
  include Syncable, Provided, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :access_token
    encrypts :raw_payload
    encrypts :raw_connection_payload
  end

  validates :name, :access_token, :reference, presence: true

  belongs_to :family
  has_many :powens_accounts, dependent: :destroy
  has_many :accounts, through: :powens_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def provider
    Provider::PowensAdapter.build_provider
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_powens_data(sync: nil, sync_connection: false)
    PowensItem::Importer.new(self, powens_provider: provider, sync: sync, sync_connection: sync_connection).import
  end

  def process_accounts
    skipped = []
    powens_accounts.includes(:account_provider, :account).each do |powens_account|
      processor = PowensAccount::Processor.new(powens_account)
      processor.process
      skipped.concat(processor.skipped_entries)
    rescue => e
      Rails.logger.error("Powens account processing failed for #{powens_account.id}: #{e.class} - #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
    end
    skipped
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.each do |account|
      account.sync_later(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
    end
  end

  def update_from_connection!(connection)
    data = connection.to_h.with_indifferent_access
    connector = data[:connector].to_h.with_indifferent_access
    connection_state = data[:state].presence || data[:error].presence

    update!(
      connection_id: data[:id].presence || connection_id,
      user_id: data[:id_user].presence || user_id,
      connector_id: data[:id_connector].presence || connector[:id],
      connector_uuid: connector[:uuid],
      connector_name: connector[:name].presence || connector_name || name,
      connector_color: connector[:color],
      connection_state: connection_state,
      status: connection_state.present? ? :requires_update : :good,
      raw_connection_payload: data
    )
  end
end

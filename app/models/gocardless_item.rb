class GocardlessItem < ApplicationRecord
  include Syncable, Provided, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :agreement_id, deterministic: true
    encrypts :requisition_id, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, :institution_id, :requisition_id, presence: true

  belongs_to :family
  has_many :gocardless_accounts, dependent: :destroy
  has_many :accounts, through: :gocardless_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def provider
    Provider::GocardlessAdapter.build_provider
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_gocardless_data(sync: nil)
    GocardlessItem::Importer.new(self, gocardless_provider: provider, sync: sync).import
  end

  def process_accounts
    skipped = []
    gocardless_accounts.includes(:account_provider, :account).each do |gocardless_account|
      processor = GocardlessAccount::Processor.new(gocardless_account)
      processor.process
      skipped.concat(processor.skipped_entries)
    rescue => e
      Rails.logger.error("GoCardless account processing failed for #{gocardless_account.id}: #{e.class} - #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
    end
    skipped
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.each do |account|
      account.sync_later(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
    end
  end
end

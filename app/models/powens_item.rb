class PowensItem < ApplicationRecord
  include Syncable, Provided, Encryptable

  USER_ACTION_CONNECTION_STATES = %w[
    SCARequired
    webauthRequired
    additionalInformationNeeded
    decoupled
    wrongpass
    actionNeeded
    passwordExpired
  ].freeze

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

  def import_latest_powens_data(sync: nil, sync_connection: false, wait_for_source_refresh: false)
    PowensItem::Importer.new(
      self,
      powens_provider: provider,
      sync: sync,
      sync_connection: sync_connection,
      wait_for_source_refresh: wait_for_source_refresh
    ).import
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
    issue = connection_issue(data)

    update!(
      connection_id: data[:id].presence || connection_id,
      user_id: data[:id_user].presence || user_id,
      connector_id: data[:id_connector].presence || connector[:id],
      connector_uuid: connector[:uuid],
      connector_name: connector[:name].presence || connector_name || name,
      connector_color: connector[:color],
      connection_state: issue&.fetch(:state),
      status: issue&.fetch(:user_action_required) ? :requires_update : :good,
      raw_connection_payload: data
    )
  end

  def connection_issue(connection)
    data = connection.to_h.with_indifferent_access
    sources = relevant_connection_sources(data)
    source_issues = sources.filter_map do |source|
      state = source[:state].presence
      next unless state

      { state: state, source: source[:name].presence }
    end

    if source_issues.any?
      states = source_issues.pluck(:state).uniq
      return {
        state: states.join(","),
        sources: source_issues.pluck(:source).compact.uniq,
        user_action_required: states.any? { |state| state.in?(USER_ACTION_CONNECTION_STATES) }
      }
    end

    # Source-level states are authoritative for multi-source connections. A
    # connection can expose a global error caused by an unlinked source while
    # every source backing the user's linked accounts remains healthy.
    return nil if Array(data[:sources]).any?

    state = data[:state].presence || data[:error].presence
    return nil unless state

    {
      state: state,
      sources: [],
      user_action_required: state.in?(USER_ACTION_CONNECTION_STATES)
    }
  end

  def reconnect_source_names(connection)
    relevant_connection_sources(connection.to_h.with_indifferent_access)
      .select { |source| source[:state].to_s.in?(USER_ACTION_CONNECTION_STATES) }
      .filter_map { |source| source[:name].presence }
      .uniq
  end

  private
    def relevant_connection_sources(connection)
      sources = Array(connection[:sources]).map { |source| source.to_h.with_indifferent_access }
      return sources if sources.empty?

      linked_account_ids = powens_accounts.joins(:account_provider).pluck("powens_accounts.account_id").map(&:to_s)
      return sources if linked_account_ids.empty?

      linked_source_ids = Array(connection[:accounts]).filter_map do |account|
        account = account.to_h.with_indifferent_access
        account[:id_source].to_s if account[:id].to_s.in?(linked_account_ids) && account[:id_source].present?
      end.uniq
      return sources if linked_source_ids.empty?

      sources.select { |source| source[:id].to_s.in?(linked_source_ids) }
    end
end

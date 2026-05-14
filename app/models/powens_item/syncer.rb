class PowensItem::Syncer
  include SyncStats::Collector

  attr_reader :powens_item

  def initialize(powens_item)
    @powens_item = powens_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Importing accounts from Powens...") if sync.respond_to?(:status_text)
    result = powens_item.import_latest_powens_data(sync: sync, sync_connection: true)
    raise StandardError.new(result[:error] || "Powens import failed") unless result[:success]

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: powens_item.powens_accounts.includes(:account_provider, :account))

    linked_ids = powens_item.powens_accounts.joins(:account_provider).joins(:account).merge(Account.visible).pluck("accounts.id")
    if linked_ids.any?
      sync.update!(status_text: "Processing Powens transactions...") if sync.respond_to?(:status_text)
      skipped_entries = powens_item.process_accounts
      collect_skip_stats(sync, skipped_entries: skipped_entries) if skipped_entries.any?
      collect_transaction_stats(sync, account_ids: linked_ids, source: "powens")
      powens_item.schedule_account_syncs(parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date)
    end

    collect_health_stats(sync, errors: nil)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ]) if sync
    raise
  end

  def perform_post_sync
    # no-op
  end
end

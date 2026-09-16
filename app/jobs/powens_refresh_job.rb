class PowensRefreshJob < ApplicationJob
  queue_as :high_priority

  RefreshPending = Class.new(StandardError)

  retry_on RefreshPending, wait: 30.seconds, attempts: 10 do |job, error|
    item = job.arguments.first
    next unless item.reload.source_refresh_baseline.any?

    item.update!(status: :refresh_failed)
    DebugLogEntry.capture(
      category: "provider_sync_error", level: "warn", message: error.message,
      source: name, provider_key: "powens", family: item.family,
      metadata: { powens_item_id: item.id, connection_id: item.connection_id, refresh_pending: true }
    )
    item.broadcast_sync_complete
  end

  def perform(item)
    item.reload
    return if item.scheduled_for_deletion? || item.source_refresh_baseline.empty?

    result = item.import_latest_powens_data(wait_for_source_refresh: true)
    raise RefreshPending, "Powens source refresh did not finish within five minutes" if result[:refresh_pending]

    if result[:success]
      item.process_accounts
      item.schedule_account_syncs
    elsif !item.requires_update?
      raise RefreshPending, result[:error]
    end
    item.broadcast_sync_complete
  end
end

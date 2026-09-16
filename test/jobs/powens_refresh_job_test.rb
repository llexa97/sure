require "test_helper"

class PowensRefreshJobTest < ActiveJob::TestCase
  setup do
    @item = PowensItem.create!(
      family: families(:dylan_family), name: "Powens", access_token: "test-token",
      connection_id: "99", reference: SecureRandom.uuid, status: :refreshing,
      raw_payload: { "sure_source_refresh" => { "directaccess" => "2026-07-14 09:29:39" } }
    )
  end

  test "pending refresh is retried without processing cached accounts" do
    @item.expects(:import_latest_powens_data).with(wait_for_source_refresh: true)
      .returns(success: false, refresh_pending: true)
    @item.expects(:process_accounts).never

    assert_enqueued_with(job: PowensRefreshJob) do
      PowensRefreshJob.perform_now(@item)
    end
    assert_predicate @item.reload, :refreshing?
  end

  test "successful refresh processes and broadcasts the fresh data" do
    @item.expects(:import_latest_powens_data).returns(success: true)
    @item.expects(:process_accounts).once
    @item.expects(:schedule_account_syncs).once
    @item.expects(:broadcast_sync_complete).once

    PowensRefreshJob.perform_now(@item)
  end

  test "exhausted retries show a delay instead of asking for authentication" do
    @item.expects(:import_latest_powens_data).returns(success: false, refresh_pending: true)
    @item.expects(:broadcast_sync_complete).once
    job = PowensRefreshJob.new(@item)
    job.executions = 9
    job.exception_executions = { [ PowensRefreshJob::RefreshPending ].to_s => 9 }

    assert_no_enqueued_jobs do
      job.perform_now
    end

    assert_predicate @item.reload, :refresh_failed?
    assert_not @item.requires_update?
    assert @item.source_refresh_baseline.any?
    assert DebugLogEntry.where(provider_key: "powens").exists?
  end

  test "obsolete jobs do not trigger another synchronization" do
    @item.clear_source_refresh!
    @item.expects(:import_latest_powens_data).never

    PowensRefreshJob.perform_now(@item)
  end

  test "a fresh authentication request stops automatic retries" do
    @item.update!(status: :requires_update)
    @item.expects(:import_latest_powens_data).returns(success: false, error: "SCARequired")
    @item.expects(:process_accounts).never
    @item.expects(:broadcast_sync_complete).once

    assert_no_enqueued_jobs do
      PowensRefreshJob.perform_now(@item)
    end
  end

  test "temporary provider failures are retried" do
    @item.expects(:import_latest_powens_data).returns(success: false, error: "Provider unavailable")
    @item.expects(:process_accounts).never

    assert_enqueued_with(job: PowensRefreshJob) do
      PowensRefreshJob.perform_now(@item)
    end
  end
end

class GocardlessItem::Importer
  attr_reader :gocardless_item, :gocardless_provider, :sync

  def initialize(gocardless_item, gocardless_provider:, sync: nil)
    @gocardless_item = gocardless_item
    @gocardless_provider = gocardless_provider
    @sync = sync
  end

  def import
    raise StandardError.new("GoCardless provider is not configured") unless gocardless_provider

    requisition = gocardless_provider.get_requisition(gocardless_item.requisition_id)
    unless requisition[:status] == "LN"
      gocardless_item.update!(status: :requires_update, raw_payload: requisition)
      return { success: false, error: "GoCardless requisition is not linked (status=#{requisition[:status]})", accounts_updated: 0, transactions_imported: 0 }
    end

    gocardless_item.update!(status: :good, raw_payload: requisition)

    accounts_updated = 0
    transactions_imported = 0
    accounts_failed = 0
    transactions_failed = 0

    Array(requisition[:accounts]).each do |account_id|
      begin
        account = import_account(account_id)
        accounts_updated += 1
        if account.current_account.present?
          tx_result = import_transactions(account)
          transactions_imported += tx_result[:count]
        end
      rescue Provider::Gocardless::GocardlessError => e
        accounts_failed += 1
        handle_provider_error(e)
        Rails.logger.warn("GoCardless import error for account #{account_id}: #{e.error_type} #{e.message}")
      rescue => e
        transactions_failed += 1
        Rails.logger.warn("GoCardless import failed for account #{account_id}: #{e.class} #{e.message}")
      end
    end

    gocardless_item.update!(last_synced_at: Time.current) if gocardless_item.has_attribute?(:last_synced_at)
    { success: accounts_failed.zero? && transactions_failed.zero?, accounts_updated: accounts_updated, accounts_failed: accounts_failed, transactions_imported: transactions_imported, transactions_failed: transactions_failed }
  end

  private
    def import_account(account_id)
      metadata = gocardless_provider.get_account_metadata(account_id)
      details = gocardless_provider.get_account_details(account_id)
      balances = gocardless_provider.get_account_balances(account_id)

      account = gocardless_item.gocardless_accounts.find_or_initialize_by(account_id: account_id.to_s)
      account.name = "GoCardless Account" if account.name.blank?
      account.save! if account.new_record?
      account.upsert_gocardless_snapshot!(metadata: metadata, details: details, balances: balances)
      account
    end

    def import_transactions(account)
      start_date = [ gocardless_item.last_synced_at&.to_date || 90.days.ago.to_date, 90.days.ago.to_date ].compact.min
      transactions = gocardless_provider.get_account_transactions(account.account_id, date_from: start_date, date_to: Date.current)
      account.upsert_gocardless_transactions_snapshot!(transactions)
      booked = Array(transactions.dig(:transactions, :booked))
      pending = include_pending? ? Array(transactions.dig(:transactions, :pending)) : []
      { count: booked.size + pending.size }
    end

    def include_pending?
      if defined?(Setting) && Setting.respond_to?(:syncs_include_pending)
        Setting.syncs_include_pending
      else
        ENV["GOCARDLESS_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[1 true yes on])
      end
    end

    def handle_provider_error(error)
      case error.error_type
      when :invalid_token, :access_denied, :not_found, :resource_suspended
        gocardless_item.update!(status: :requires_update)
      when :rate_limited
        sync&.update!(sync_stats: (sync.sync_stats || {}).merge("rate_limited" => true, "rate_limit_headers" => error.headers)) if sync&.respond_to?(:sync_stats)
      end
    end
end

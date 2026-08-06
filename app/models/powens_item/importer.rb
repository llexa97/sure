class PowensItem::Importer
  SOURCE_REFRESH_POLL_ATTEMPTS = 10
  SOURCE_REFRESH_POLL_INTERVAL = 2.seconds

  attr_reader :powens_item, :powens_provider, :sync, :sync_connection, :wait_for_source_refresh,
              :source_refresh_poll_attempts, :source_refresh_poll_interval

  def initialize(
    powens_item,
    powens_provider:,
    sync: nil,
    sync_connection: false,
    wait_for_source_refresh: false,
    source_refresh_poll_attempts: SOURCE_REFRESH_POLL_ATTEMPTS,
    source_refresh_poll_interval: SOURCE_REFRESH_POLL_INTERVAL
  )
    @powens_item = powens_item
    @powens_provider = powens_provider
    @sync = sync
    @sync_connection = sync_connection
    @wait_for_source_refresh = wait_for_source_refresh
    @source_refresh_poll_attempts = [ source_refresh_poll_attempts.to_i, 1 ].max
    @source_refresh_poll_interval = source_refresh_poll_interval
  end

  def import
    raise StandardError.new("Powens provider is not configured") unless powens_provider
    raise StandardError.new("Powens access token is missing") if powens_item.access_token.blank?

    refresh_connection if sync_connection && powens_item.connection_id.present? && !powens_item.requires_update?

    connection, pending_refresh_sources = fetch_connection_after_reconnect
    powens_item.update_from_connection!(connection)

    if (issue = powens_item.connection_issue(connection))
      source_label = issue[:sources].any? ? " for #{issue[:sources].join(', ')}" : ""
      action = issue[:user_action_required] ? "requires user action" : "could not refresh"
      return failure_result(
        "Powens connection #{action}#{source_label} (state=#{issue[:state]})",
        state: issue[:state],
        sources: issue[:sources],
        user_action_required: issue[:user_action_required]
      )
    end

    if pending_refresh_sources.any?
      powens_item.update!(status: :requires_update)
      return failure_result(
        "Powens is still refreshing #{pending_refresh_sources.join(', ')}; cached values were not imported",
        sources: pending_refresh_sources,
        refresh_pending: true
      )
    end

    accounts_payload = fetch_accounts(connection)
    accounts_updated = 0
    accounts_failed = 0
    transactions_imported = 0
    transactions_failed = 0

    accounts_payload.each do |account_data|
      begin
        account = import_account(account_data)
        accounts_updated += 1

        if account.current_account.present?
          import_holdings(account) if account.investment?
          tx_result = import_transactions(account)
          transactions_imported += tx_result[:count]
        end
      rescue Provider::Powens::PowensError => e
        accounts_failed += 1
        handle_provider_error(e)
        Rails.logger.warn("Powens import error for account #{account_data[:id] || account_data['id']}: #{e.error_type} #{e.message}")
      rescue => e
        transactions_failed += 1
        Rails.logger.warn("Powens import failed for account #{account_data[:id] || account_data['id']}: #{e.class} #{e.message}")
      end
    end

    powens_item.update!(last_synced_at: Time.current) if powens_item.has_attribute?(:last_synced_at)
    { success: accounts_failed.zero? && transactions_failed.zero?, accounts_updated: accounts_updated, accounts_failed: accounts_failed, transactions_imported: transactions_imported, transactions_failed: transactions_failed }
  rescue Provider::Powens::PowensError => e
    handle_provider_error(e)
    { success: false, error: e.message, accounts_updated: 0, transactions_imported: 0 }
  end

  private
    def refresh_connection
      powens_provider.sync_connection(powens_item.access_token, powens_item.connection_id, psu_requested: false)
    rescue Provider::Powens::PowensError => e
      handle_provider_error(e)
      Rails.logger.warn("Powens connection refresh failed for #{powens_item.id}: #{e.error_type} #{e.message}")
    end

    def fetch_connection
      if powens_item.connection_id.present?
        powens_provider.get_connection(powens_item.access_token, powens_item.connection_id, expand: "accounts,connector,sources")
      else
        { accounts: [] }
      end
    end

    def fetch_connection_after_reconnect
      return [ fetch_connection, [] ] unless wait_for_source_refresh

      baseline = powens_item.raw_connection_payload.to_h.with_indifferent_access
      source_names = powens_item.reconnect_source_names(baseline)
      return [ fetch_connection, [] ] if source_names.empty?

      baseline_updates = source_names.index_with do |source_name|
        source_by_name(baseline, source_name)&.dig(:last_update)
      end
      connection = nil

      source_refresh_poll_attempts.times do |attempt|
        connection = fetch_connection
        return [ connection, [] ] if sources_refreshed?(connection, source_names, baseline_updates)

        sleep(source_refresh_poll_interval) if attempt < source_refresh_poll_attempts - 1
      end

      [ connection, source_names ]
    end

    def sources_refreshed?(connection, source_names, baseline_updates)
      source_names.all? do |source_name|
        source = source_by_name(connection, source_name)

        source && source[:state].blank? && newer_timestamp?(source[:last_update], baseline_updates[source_name])
      end
    end

    def source_by_name(connection, source_name)
      Array(connection[:sources])
        .map { |source| source.to_h.with_indifferent_access }
        .find { |source| source[:name].to_s == source_name.to_s }
    end

    def newer_timestamp?(current_value, baseline_value)
      return false if current_value.blank?
      return true if baseline_value.blank?

      Time.zone.parse(current_value.to_s) > Time.zone.parse(baseline_value.to_s)
    rescue ArgumentError, TypeError
      current_value.to_s != baseline_value.to_s
    end

    def failure_result(error, metadata = {})
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: error,
        source: self.class.name,
        provider_key: "powens",
        family: powens_item.family,
        metadata: metadata.merge(
          powens_item_id: powens_item.id,
          connection_id: powens_item.connection_id,
          account_provider_ids: powens_item.powens_accounts
            .joins(:account_provider)
            .pluck("account_providers.id")
        )
      )

      {
        success: false,
        error: error,
        accounts_updated: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end

    def fetch_accounts(connection)
      accounts = Array(connection[:accounts])
      return accounts if accounts.any?

      payload = powens_provider.list_accounts(powens_item.access_token, connection_id: powens_item.connection_id, all: true)
      Array(payload[:accounts])
    end

    def import_account(account_data)
      data = account_data.with_indifferent_access
      account_id = data[:id].to_s
      raise ArgumentError, "Powens account id is missing" if account_id.blank?

      account = powens_item.powens_accounts.find_or_initialize_by(account_id: account_id)
      account.name = "Powens Account" if account.name.blank?
      account.save! if account.new_record?
      account.upsert_powens_snapshot!(data)
      account
    end

    def import_holdings(account)
      payload = powens_provider.list_account_investments(powens_item.access_token, account.account_id)
      account.upsert_powens_holdings_snapshot!(payload)
    end

    def import_transactions(account)
      transactions_payload = powens_provider.list_account_transactions(
        powens_item.access_token,
        account.account_id,
        min_date: determine_sync_start_date(account)
      )

      transactions = Array(transactions_payload[:transactions])
      transactions = transactions.reject { |tx| ActiveModel::Type::Boolean.new.cast(tx.with_indifferent_access[:coming]) } unless include_pending?

      account.upsert_powens_transactions_snapshot!(transactions)
      { count: transactions.count }
    end

    def determine_sync_start_date(account)
      return nil if first_transaction_import?(account)

      [
        powens_item.last_synced_at&.to_date || 90.days.ago.to_date,
        90.days.ago.to_date
      ].compact.min
    end

    def first_transaction_import?(account)
      Array(account.raw_transactions_payload).empty? &&
        account.current_account&.entries&.where(source: "powens")&.none?
    end

    def include_pending?
      settings_enabled = defined?(Setting) && Setting.respond_to?(:syncs_include_pending) && Setting.syncs_include_pending
      env_enabled = ENV["POWENS_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[1 true yes on])

      settings_enabled || env_enabled
    end

    def handle_provider_error(error)
      case error.error_type
      when :invalid_token, :access_denied, :not_found
        powens_item.update!(status: :requires_update)
      when :rate_limited
        sync&.update!(sync_stats: (sync.sync_stats || {}).merge("rate_limited" => true, "rate_limit_headers" => error.headers)) if sync&.respond_to?(:sync_stats)
      end
    end
end

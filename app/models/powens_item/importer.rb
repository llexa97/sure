class PowensItem::Importer
  attr_reader :powens_item, :powens_provider, :sync, :sync_connection

  def initialize(powens_item, powens_provider:, sync: nil, sync_connection: false)
    @powens_item = powens_item
    @powens_provider = powens_provider
    @sync = sync
    @sync_connection = sync_connection
  end

  def import
    raise StandardError.new("Powens provider is not configured") unless powens_provider
    raise StandardError.new("Powens access token is missing") if powens_item.access_token.blank?

    refresh_connection if sync_connection && powens_item.connection_id.present?

    connection = fetch_connection
    powens_item.update_from_connection!(connection)

    if powens_item.requires_update? && Array(connection[:accounts]).blank?
      return { success: false, error: "Powens connection requires user action (state=#{powens_item.connection_state})", accounts_updated: 0, transactions_imported: 0 }
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
        powens_provider.get_connection(powens_item.access_token, powens_item.connection_id, expand: "accounts,connector")
      else
        { accounts: [] }
      end
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

    def import_transactions(account)
      transactions_payload = powens_provider.list_account_transactions(
        powens_item.access_token,
        account.account_id,
        min_date: determine_sync_start_date,
        max_date: Date.current
      )

      transactions = Array(transactions_payload[:transactions])
      transactions = transactions.reject { |tx| ActiveModel::Type::Boolean.new.cast(tx.with_indifferent_access[:coming]) } unless include_pending?

      account.upsert_powens_transactions_snapshot!(transactions)
      { count: transactions.count }
    end

    def determine_sync_start_date
      [
        powens_item.last_synced_at&.to_date || 90.days.ago.to_date,
        90.days.ago.to_date
      ].compact.min
    end

    def include_pending?
      settings_enabled = defined?(Setting) && Setting.respond_to?(:syncs_include_pending) && Setting.syncs_include_pending
      env_enabled = ENV["POWENS_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[1 true yes on])

      settings_enabled || env_enabled
    end

    def handle_provider_error(error)
      case error.error_type
      when :invalid_token, :access_denied, :not_found, :conflict
        powens_item.update!(status: :requires_update)
      when :rate_limited
        sync&.update!(sync_stats: (sync.sync_stats || {}).merge("rate_limited" => true, "rate_limit_headers" => error.headers)) if sync&.respond_to?(:sync_stats)
      end
    end
end

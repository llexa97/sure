class PowensItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_powens_item, only: %i[destroy sync reconnect setup_accounts complete_account_setup]

  def new
    @powens_provider = Provider::PowensAdapter.build_provider
  end

  def create
    provider = Provider::PowensAdapter.build_provider
    return redirect_to settings_providers_path, alert: "Powens is not configured" unless provider

    token = provider.create_user_token
    reference = SecureRandom.uuid
    item = Current.family.create_powens_item!(
      auth_token: token[:auth_token],
      user_id: token[:id_user],
      reference: reference,
      raw_payload: token
    )

    code = provider.generate_temporary_code(item.access_token, type: "singleAccess")
    redirect_to provider.connect_webview_url(
      redirect_uri: callback_powens_items_url,
      code: code[:code],
      state: reference,
      lang: I18n.locale
    ), allow_other_host: true
  rescue Provider::Powens::PowensError => e
    redirect_to new_powens_item_path, alert: "Powens error: #{e.message}"
  end

  def callback
    if params[:error].present?
      return redirect_to accounts_path, alert: "Powens connection failed: #{params[:error_description].presence || params[:error]}"
    end

    item = Current.family.powens_items.active.find_by(reference: params[:state])
    return redirect_to accounts_path, alert: "Powens connection not found" unless item

    item.update!(connection_id: selected_connection_id) if selected_connection_id.present?

    if item.access_token.blank? && params[:code].present?
      provider = Provider::PowensAdapter.build_provider
      token = provider.exchange_temporary_code(params[:code])
      item.update!(access_token: token[:access_token])
    end

    result = item.import_latest_powens_data(wait_for_source_refresh: item.requires_update?)
    if result[:success]
      item.process_accounts
      item.schedule_account_syncs
      redirect_to setup_accounts_powens_item_path(item), notice: "Powens connection linked. Select accounts to import."
    else
      redirect_to accounts_path, alert: result[:error]
    end
  rescue Provider::Powens::PowensError => e
    redirect_to accounts_path, alert: "Powens error: #{e.message}"
  end

  def reconnect
    provider = Provider::PowensAdapter.build_provider
    return redirect_to settings_providers_path, alert: "Powens is not configured" unless provider
    return redirect_to accounts_path, alert: "Powens connection is missing" if @powens_item.connection_id.blank?

    connection = provider.get_connection(
      @powens_item.access_token,
      @powens_item.connection_id,
      expand: "accounts,connector,sources"
    )
    @powens_item.update_from_connection!(connection)
    reconnect_sources = @powens_item.reconnect_source_names(connection)

    code = provider.generate_temporary_code(@powens_item.access_token, type: "singleAccess")
    redirect_to provider.reconnect_webview_url(
      redirect_uri: callback_powens_items_url,
      code: code[:code],
      connection_id: @powens_item.connection_id,
      state: @powens_item.reference,
      lang: I18n.locale,
      reset_credentials: reconnect_sources.any? ? true : nil,
      connection_sources: reconnect_sources
    ), allow_other_host: true
  rescue Provider::Powens::PowensError => e
    redirect_to accounts_path, alert: "Powens error: #{e.message}"
  end

  def setup_accounts
    @powens_accounts = @powens_item.powens_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def complete_account_setup
    selected = params.fetch(:account_ids, [])
    selected.each do |powens_account_id|
      provider_account = @powens_item.powens_accounts.find(powens_account_id)
      account_type = suggested_accountable_type(provider_account)
      balance = provider_account.current_balance_for(account_type) || 0

      attributes = {
        family: Current.family,
        name: provider_account.name,
        balance: balance,
        currency: provider_account.currency || Current.family.primary_currency_code,
        accountable_type: account_type,
        accountable_attributes: suggested_accountable_attributes(provider_account)
      }
      # For investment accounts, the provider balance is the portfolio valuation,
      # not cash. The holdings sync repopulates it correctly; default to zero.
      attributes[:cash_balance] = 0 if account_type == "Investment"

      account = Account.create_and_sync(attributes, skip_initial_sync: true)
      AccountProvider.find_or_create_by!(account: account, provider: provider_account)
    end

    @powens_item.sync_later if selected.any?
    redirect_to accounts_path, notice: "Powens accounts linked"
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_powens_accounts = Current.family.powens_items.active.includes(:powens_accounts).flat_map(&:powens_accounts).select { |a| a.account_provider.nil? }
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    provider_account = PowensAccount.find(params[:powens_account_id])
    unless provider_account.powens_item.family == Current.family
      return redirect_to account_path(account), alert: "Invalid Powens account selected"
    end

    AccountProvider.create!(account: account, provider: provider_account)
    provider_account.powens_item.sync_later
    redirect_to accounts_path, notice: "Account linked to Powens"
  end

  def sync
    @powens_item.sync_later unless @powens_item.syncing?
    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def destroy
    provider = Provider::PowensAdapter.build_provider
    provider&.delete_connection(@powens_item.access_token, @powens_item.connection_id) if @powens_item.connection_id.present?
    provider&.revoke_token(@powens_item.access_token) if @powens_item.access_token.present?
  rescue Provider::Powens::PowensError => e
    Rails.logger.warn("Failed to delete Powens connection: #{e.message}")
  ensure
    @powens_item.destroy_later
    redirect_to accounts_path, notice: "Powens connection removed"
  end

  private
    def set_powens_item
      @powens_item = Current.family.powens_items.find(params[:id])
    end

    def selected_connection_id
      params[:connection_id].presence || params[:connection_ids].to_s.split(",").first.presence
    end

    def suggested_accountable_type(provider_account)
      requested = params[:accountable_type].presence
      return requested if requested.in?(Provider::PowensAdapter.supported_account_types)

      provider_account.suggested_account_type
    end

    def suggested_accountable_attributes(provider_account)
      attrs = {}
      subtype = provider_account.suggested_subtype
      attrs[:subtype] = subtype if subtype.present?
      attrs
    end
end

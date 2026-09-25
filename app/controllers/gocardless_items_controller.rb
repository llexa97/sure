class GocardlessItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_gocardless_item, only: %i[destroy sync setup_accounts complete_account_setup]

  def new
    @country = params[:country].presence || Current.family.country.presence || "FR"
    @institutions = []
    if params[:country].present?
      provider = Provider::GocardlessAdapter.build_provider
      @institutions = provider ? provider.get_institutions(country: @country) : []
    end
  rescue Provider::Gocardless::GocardlessError => e
    @institutions = []
    flash.now[:alert] = "GoCardless error: #{e.message}"
  end

  def create
    provider = Provider::GocardlessAdapter.build_provider
    return redirect_to settings_providers_path, alert: "GoCardless is not configured" unless provider

    country = params.require(:country).to_s.upcase
    institution_id = params.require(:institution_id)
    institution = provider.get_institution(institution_id)
    reference = SecureRandom.uuid

    body = {
      redirect_url: callback_gocardless_items_url(ref: reference),
      institution_id: institution_id,
      max_historical_days: special_continuous_access_bank?(institution_id) ? 90 : (institution[:transaction_total_days].presence || 90),
      access_valid_for_days: institution[:max_access_valid_for_days].presence || 90,
      user_language: I18n.locale.to_s.split("-").first,
      reference: reference,
      redirect_immediate: false,
      account_selection: Array(institution[:supported_features]).include?("account_selection")
    }

    requisition = begin
      provider.init_session(**body)
    rescue Provider::Gocardless::GocardlessError
      provider.init_session(**body.merge(max_historical_days: 89, access_valid_for_days: 90))
    end

    Current.family.create_gocardless_item!(institution: institution, country_code: country, requisition: requisition, reference: reference)
    redirect_to requisition[:link], allow_other_host: true
  rescue Provider::Gocardless::GocardlessError => e
    redirect_to new_gocardless_item_path(country: params[:country]), alert: "GoCardless error: #{e.message}"
  end

  def callback
    item = Current.family.gocardless_items.order(created_at: :desc).find_by(reference: params[:ref]) || Current.family.gocardless_items.order(created_at: :desc).first
    return redirect_to accounts_path, alert: "GoCardless connection not found" unless item

    result = item.import_latest_gocardless_data
    if result[:success]
      redirect_to setup_accounts_gocardless_item_path(item), notice: "GoCardless connection linked. Select accounts to import."
    else
      redirect_to accounts_path, alert: result[:error]
    end
  end

  def setup_accounts
    @gocardless_accounts = @gocardless_item.gocardless_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def complete_account_setup
    selected = params.fetch(:account_ids, [])
    selected.each do |gocardless_account_id|
      provider_account = @gocardless_item.gocardless_accounts.find(gocardless_account_id)
      account = Account.create_and_sync(
        {
          family: Current.family,
          name: provider_account.name,
          balance: provider_account.current_balance || 0,
          currency: provider_account.currency || Current.family.primary_currency_code,
          accountable_type: suggested_accountable_type(provider_account),
          accountable_attributes: {}
        },
        skip_initial_sync: true
      )
      AccountProvider.find_or_create_by!(account: account, provider: provider_account)
    end

    @gocardless_item.sync_later if selected.any?
    redirect_to accounts_path, notice: "GoCardless accounts linked"
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_gocardless_accounts = Current.family.gocardless_items.includes(:gocardless_accounts).flat_map(&:gocardless_accounts).select { |a| a.account_provider.nil? }
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    provider_account = GocardlessAccount.find(params[:gocardless_account_id])
    unless provider_account.gocardless_item.family == Current.family
      return redirect_to account_path(account), alert: "Invalid GoCardless account selected"
    end
    AccountProvider.create!(account: account, provider: provider_account)
    provider_account.gocardless_item.sync_later
    redirect_to accounts_path, notice: "Account linked to GoCardless"
  end

  def sync
    @gocardless_item.sync_later unless @gocardless_item.syncing?
    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def destroy
    provider = Provider::GocardlessAdapter.build_provider
    provider&.delete_requisition(@gocardless_item.requisition_id)
  rescue Provider::Gocardless::GocardlessError => e
    Rails.logger.warn("Failed to delete GoCardless requisition: #{e.message}")
  ensure
    @gocardless_item.destroy_later
    redirect_to accounts_path, notice: "GoCardless connection removed"
  end

  private
    def set_gocardless_item
      @gocardless_item = Current.family.gocardless_items.find(params[:id])
    end

    def suggested_accountable_type(provider_account)
      type = provider_account.account_type.to_s.upcase
      return "CreditCard" if type.include?("CARD") || type.include?("CRCD")
      "Depository"
    end

    def special_continuous_access_bank?(institution_id)
      prefixes = %w[BRED_BREDFRPPXXX LUMINOR_ SWEDBANK_ SEB_ BANKINTER_BKBKESMM CAIXABANK_CAIXESBB BBVA_BBVAESMM]
      prefixes.any? { |prefix| institution_id.to_s.start_with?(prefix) }
    end
end

class Provider::Gocardless < Provider
  include HTTParty
  extend SslConfigurable

  BASE_URL = "https://bankaccountdata.gocardless.com/api/v2".freeze
  SAFE_ID = /\A[a-zA-Z0-9_-]+\z/
  DEFAULT_ACCESS_SCOPE = %w[balances details transactions].freeze

  headers "Accept" => "application/json", "Content-Type" => "application/json", "User-Agent" => "Sure Finance GoCardless Client"
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :secret_id, :secret_key, :access_token

  def initialize(secret_id:, secret_key:)
    @secret_id = secret_id
    @secret_key = secret_key
  end

  def configured?
    secret_id.present? && secret_key.present?
  end

  def generate_token!
    response = self.class.post("#{BASE_URL}/token/new/", body: { secret_id: secret_id, secret_key: secret_key }.to_json)
    data = handle_response(response)
    @access_token = data[:access]
    data
  end

  def refresh_token!(refresh_token)
    response = self.class.post("#{BASE_URL}/token/refresh/", body: { refresh: refresh_token }.to_json)
    data = handle_response(response)
    @access_token = data[:access]
    data
  end

  def get_institutions(country:)
    ensure_token!
    self.class.get("#{BASE_URL}/institutions/", headers: auth_headers, query: { country: country.to_s.upcase }).then { |r| handle_response(r) }
  end

  def get_institution(id)
    ensure_token!
    safe_id = sanitize_id!(id, "institution id")
    self.class.get("#{BASE_URL}/institutions/#{safe_id}/", headers: auth_headers).then { |r| handle_response(r) }
  end

  def init_session(redirect_url:, institution_id:, max_historical_days: 90, access_valid_for_days: 90, user_language: "en", reference: SecureRandom.uuid, ssn: nil, redirect_immediate: false, account_selection: false)
    agreement = create_agreement(
      institution_id: institution_id,
      max_historical_days: max_historical_days,
      access_valid_for_days: access_valid_for_days
    )

    create_requisition(
      redirect_url: redirect_url,
      institution_id: institution_id,
      agreement_id: agreement[:id],
      user_language: user_language,
      reference: reference,
      ssn: ssn,
      redirect_immediate: redirect_immediate,
      account_selection: account_selection
    )
  end

  def create_agreement(institution_id:, max_historical_days: 90, access_valid_for_days: 90, access_scope: DEFAULT_ACCESS_SCOPE)
    ensure_token!
    body = {
      institution_id: sanitize_id!(institution_id, "institution id"),
      max_historical_days: max_historical_days.to_i,
      access_valid_for_days: access_valid_for_days.to_i,
      access_scope: access_scope
    }
    self.class.post("#{BASE_URL}/agreements/enduser/", headers: auth_headers, body: body.to_json).then { |r| handle_response(r) }
  end

  def create_requisition(redirect_url:, institution_id:, agreement_id:, user_language: "en", reference: nil, ssn: nil, redirect_immediate: false, account_selection: false)
    ensure_token!
    body = {
      redirect: redirect_url,
      institution_id: sanitize_id!(institution_id, "institution id"),
      agreement: sanitize_id!(agreement_id, "agreement id"),
      user_language: user_language,
      reference: reference,
      ssn: ssn,
      redirect_immediate: redirect_immediate,
      account_selection: account_selection
    }.compact
    self.class.post("#{BASE_URL}/requisitions/", headers: auth_headers, body: body.to_json).then { |r| handle_response(r) }
  end

  def get_requisition(requisition_id)
    ensure_token!
    safe_id = sanitize_id!(requisition_id, "requisition id")
    self.class.get("#{BASE_URL}/requisitions/#{safe_id}/", headers: auth_headers).then { |r| handle_response(r) }
  end

  def delete_requisition(requisition_id)
    ensure_token!
    safe_id = sanitize_id!(requisition_id, "requisition id")
    self.class.delete("#{BASE_URL}/requisitions/#{safe_id}/", headers: auth_headers).then { |r| handle_response(r) }
  end

  def get_account_metadata(account_id)
    ensure_token!
    safe_id = sanitize_id!(account_id, "account id")
    self.class.get("#{BASE_URL}/accounts/#{safe_id}/", headers: auth_headers).then { |r| handle_response(r) }
  end

  def get_account_details(account_id)
    ensure_token!
    safe_id = sanitize_id!(account_id, "account id")
    self.class.get("#{BASE_URL}/accounts/#{safe_id}/details/", headers: auth_headers).then { |r| handle_response(r) }
  end

  def get_account_balances(account_id)
    ensure_token!
    safe_id = sanitize_id!(account_id, "account id")
    self.class.get("#{BASE_URL}/accounts/#{safe_id}/balances/", headers: auth_headers).then { |r| handle_response(r) }
  end

  def get_account_transactions(account_id, date_from: nil, date_to: nil)
    ensure_token!
    safe_id = sanitize_id!(account_id, "account id")
    query = { date_from: date_from, date_to: date_to }.compact
    self.class.get("#{BASE_URL}/accounts/#{safe_id}/transactions/", headers: auth_headers, query: query).then { |r| handle_response(r) }
  end

  class GocardlessError < StandardError
    attr_reader :error_type, :status, :details, :headers

    def initialize(message, error_type = :unknown, status: nil, details: nil, headers: {})
      super(message)
      @error_type = error_type
      @status = status
      @details = details
      @headers = headers || {}
    end
  end

  private
    def ensure_token!
      generate_token! if access_token.blank? || expired_jwt?(access_token)
    end

    def expired_jwt?(token)
      segment = token.split(".")[1].to_s
      segment += "=" * ((4 - segment.length % 4) % 4)
      payload = JSON.parse(Base64.urlsafe_decode64(segment))
      Time.current.to_i >= payload["exp"].to_i
    rescue
      true
    end

    def auth_headers
      { "Authorization" => "Bearer #{access_token}" }
    end

    def sanitize_id!(id, label)
      value = id.to_s
      raise GocardlessError.new("Invalid GoCardless #{label}", :invalid_input) unless value.match?(SAFE_ID)
      value
    end

    def handle_response(response)
      case response.code
      when 200, 201
        parse_response_body(response)
      when 204
        {}
      when 400
        raise_error(response, :invalid_input)
      when 401
        @access_token = nil
        raise_error(response, :invalid_token)
      when 403
        raise_error(response, :access_denied)
      when 404
        raise_error(response, :not_found)
      when 409
        raise_error(response, :resource_suspended)
      when 429
        raise_error(response, :rate_limited)
      when 500
        raise_error(response, :unknown)
      when 503
        raise_error(response, :service_unavailable)
      else
        raise_error(response, :fetch_failed)
      end
    end

    def parse_response_body(response)
      return {} if response.body.blank?
      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError
      raise GocardlessError.new("Failed to parse GoCardless response", :parse_error, status: response.code, details: response.body)
    end

    def raise_error(response, type)
      details = parse_response_body(response) rescue response.body
      raise GocardlessError.new("GoCardless API error #{response.code}", type, status: response.code, details: details, headers: response.headers.to_h)
    end
end

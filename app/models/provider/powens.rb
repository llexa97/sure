class Provider::Powens < Provider
  include HTTParty
  extend SslConfigurable

  DEFAULT_WEBVIEW_BASE_URL = "https://webview.powens.com".freeze
  DEFAULT_TRANSACTION_LIMIT = 1000
  MAX_PAGINATION_PAGES = 50

  headers "Accept" => "application/json",
          "Content-Type" => "application/json",
          "User-Agent" => "Sure Finance Powens Client"
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :domain, :client_id, :client_secret, :webview_base_url

  def initialize(domain:, client_id:, client_secret:, webview_base_url: DEFAULT_WEBVIEW_BASE_URL)
    @domain = normalize_domain(domain)
    @client_id = client_id.to_s.strip
    @client_secret = client_secret.to_s.strip
    @webview_base_url = webview_base_url.to_s.strip.presence || DEFAULT_WEBVIEW_BASE_URL
  end

  def configured?
    domain.present? && client_id.present? && client_secret.present?
  end

  def api_host
    domain.end_with?(".biapi.pro") ? domain : "#{domain}.biapi.pro"
  end

  def base_url
    "https://#{api_host}/2.0"
  end

  def create_user_token
    request(
      :post,
      "#{base_url}/auth/init",
      body: {
        client_id: client_id,
        client_secret: client_secret
      }
    )
  end

  def generate_temporary_code(access_token, type: "singleAccess")
    request(
      :get,
      "#{base_url}/auth/token/code",
      access_token: access_token,
      query: { type: type }
    )
  end

  def exchange_temporary_code(code)
    request(
      :post,
      "#{base_url}/auth/token/access",
      body: {
        grant_type: "authorization_code",
        client_id: client_id,
        client_secret: client_secret,
        code: code
      }
    )
  end

  def revoke_token(access_token)
    request(:delete, "#{base_url}/auth/token", access_token: access_token)
  end

  def get_connection(access_token, connection_id, expand: "accounts,connector")
    request(
      :get,
      "#{base_url}/users/me/connections/#{connection_id}",
      access_token: access_token,
      query: { expand: expand }
    )
  end

  def sync_connection(access_token, connection_id, psu_requested: false)
    request(
      :put,
      "#{base_url}/users/me/connections/#{connection_id}",
      access_token: access_token,
      query: { psu_requested: psu_requested }
    )
  end

  def delete_connection(access_token, connection_id)
    request(:delete, "#{base_url}/users/me/connections/#{connection_id}", access_token: access_token)
  end

  def list_accounts(access_token, connection_id: nil, all: true)
    path = if connection_id.present?
      "#{base_url}/users/me/connections/#{connection_id}/accounts"
    else
      "#{base_url}/users/me/accounts"
    end

    query = {}
    query[:all] = "" if all

    request(:get, path, access_token: access_token, query: query)
  end

  def update_account(access_token, account_id, attributes, all: true)
    query = {}
    query[:all] = "" if all

    request(
      :post,
      "#{base_url}/users/me/accounts/#{account_id}",
      access_token: access_token,
      query: query,
      body: attributes
    )
  end

  def list_account_investments(access_token, account_id, all: true)
    query = {}
    query[:all] = "" if all

    request(
      :get,
      "#{base_url}/users/me/accounts/#{account_id}/investments",
      access_token: access_token,
      query: query
    )
  end

  def list_account_transactions(access_token, account_id, min_date: nil, max_date: nil, limit: DEFAULT_TRANSACTION_LIMIT, all: false)
    query = {
      limit: limit,
      filter: "date",
      min_date: min_date,
      max_date: max_date
    }.compact
    query[:all] = "" if all

    fetch_paginated(
      "#{base_url}/users/me/accounts/#{account_id}/transactions",
      access_token: access_token,
      query: query
    )
  end

  def connect_webview_url(redirect_uri:, code:, state:, lang: I18n.locale, connector_capabilities: "bank")
    webview_url(
      "connect",
      redirect_uri: redirect_uri,
      code: code,
      state: state,
      lang: lang,
      connector_capabilities: connector_capabilities
    )
  end

  def reconnect_webview_url(redirect_uri:, code:, connection_id:, state:, lang: I18n.locale)
    webview_url(
      "reconnect",
      redirect_uri: redirect_uri,
      code: code,
      connection_id: connection_id,
      state: state,
      lang: lang
    )
  end

  class PowensError < StandardError
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
    def webview_url(flow, lang:, **params)
      language = lang.to_s.split("-").first.presence || "en"
      query = {
        domain: api_host,
        client_id: client_id
      }.merge(params).compact

      "#{webview_base_url}/#{language}/#{flow}?#{URI.encode_www_form(query)}"
    end

    def fetch_paginated(url, access_token:, query: {})
      transactions = []
      next_url = url
      next_query = query
      page_count = 0
      payload = nil

      loop do
        page_count += 1
        raise PowensError.new("Powens pagination limit exceeded", :pagination_limit) if page_count > MAX_PAGINATION_PAGES

        payload = request(:get, next_url, access_token: access_token, query: next_query)
        transactions.concat(Array(payload[:transactions]))

        href = payload.dig(:_links, :next, :href)
        break if href.blank?

        next_url = absolute_url(href)
        next_query = {}
      end

      (payload || {}).merge(transactions: transactions)
    end

    def absolute_url(href)
      href = href.to_s
      return href if href.match?(%r{\Ahttps?://})

      base = href.start_with?("/") ? "https://#{api_host}/" : "#{base_url}/"
      URI.join(base, href).to_s
    end

    def request(method, url, access_token: nil, query: {}, body: nil)
      options = {}
      options[:headers] = auth_headers(access_token) if access_token.present?
      options[:query] = query if query.present?
      options[:body] = body.to_json if body.present?

      response = self.class.public_send(method, url, options)
      handle_response(response)
    rescue PowensError
      raise
    rescue => e
      raise PowensError.new("Powens request failed: #{e.message}", :request_failed)
    end

    def auth_headers(access_token)
      { "Authorization" => "Bearer #{access_token}" }
    end

    def handle_response(response)
      case response.code
      when 200, 201, 202
        parse_response_body(response)
      when 204
        {}
      when 400
        raise_error(response, :invalid_input)
      when 401
        raise_error(response, :invalid_token)
      when 403
        raise_error(response, :access_denied)
      when 404
        raise_error(response, :not_found)
      when 409
        raise_error(response, :conflict)
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
      raise PowensError.new("Failed to parse Powens response", :parse_error, status: response.code, details: response.body)
    end

    def raise_error(response, type)
      details = parse_response_body(response) rescue response.body
      message = details.is_a?(Hash) ? (details[:message].presence || details[:error_description].presence || details[:code].presence) : nil
      raise PowensError.new(message || "Powens API error #{response.code}", type, status: response.code, details: details, headers: response.headers.to_h)
    end

    def normalize_domain(value)
      normalized = value.to_s.strip
      normalized = normalized.sub(%r{\Ahttps?://}, "")
      normalized = normalized.sub(%r{/2\.0/?\z}, "")
      normalized = normalized.sub(%r{/+\z}, "")
      normalized.sub(/\.biapi\.pro\z/, "")
    end
end

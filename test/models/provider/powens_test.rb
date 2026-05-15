require "test_helper"

class Provider::PowensTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body, :headers, keyword_init: true)

  setup do
    @provider = Provider::Powens.new(
      domain: "demo-sandbox.biapi.pro",
      client_id: "client_123",
      client_secret: "secret_456"
    )
  end

  test "normalizes sandbox domain and API base URL" do
    provider = Provider::Powens.new(
      domain: "https://demo-sandbox.biapi.pro/2.0/",
      client_id: "client_123",
      client_secret: "secret_456"
    )

    assert_equal "demo-sandbox.biapi.pro", provider.api_host
    assert_equal "https://demo-sandbox.biapi.pro/2.0", provider.base_url
  end

  test "builds connect webview URL with state and callback" do
    url = @provider.connect_webview_url(
      redirect_uri: "https://sure.test/powens_items/callback",
      code: "tmp-code",
      state: "state-123",
      lang: "fr-FR"
    )

    uri = URI.parse(url)
    params = Rack::Utils.parse_query(uri.query)

    assert_equal "https", uri.scheme
    assert_equal "webview.powens.com", uri.host
    assert_equal "/fr/connect", uri.path
    assert_equal "demo-sandbox.biapi.pro", params["domain"]
    assert_equal "client_123", params["client_id"]
    assert_equal "tmp-code", params["code"]
    assert_equal "state-123", params["state"]
    assert_equal "https://sure.test/powens_items/callback", params["redirect_uri"]
    assert_equal "bank", params["connector_capabilities"]
  end

  test "creates a user token with client credentials" do
    Provider::Powens.expects(:post)
      .with(
        "https://demo-sandbox.biapi.pro/2.0/auth/init",
        has_entries(body: { client_id: "client_123", client_secret: "secret_456" }.to_json)
      )
      .returns(Response.new(code: 200, body: { auth_token: "user-token", id_user: 42 }.to_json, headers: {}))

    result = @provider.create_user_token

    assert_equal "user-token", result[:auth_token]
    assert_equal 42, result[:id_user]
  end

  test "lists account transactions with pagination" do
    first_page = {
      transactions: [
        { id: 1, id_account: 11, wording: "Account 11" }
      ],
      _links: { next: { href: "/2.0/users/me/accounts/11/transactions?page=2" } }
    }
    second_page = {
      transactions: [
        { id: 3, id_account: 11, wording: "Account 11 again" }
      ]
    }

    Provider::Powens.expects(:get)
      .with(
        "https://demo-sandbox.biapi.pro/2.0/users/me/accounts/11/transactions",
        has_entries(
          headers: { "Authorization" => "Bearer user-token" },
          query: has_entries(limit: Provider::Powens::DEFAULT_TRANSACTION_LIMIT, filter: "date")
        )
      )
      .returns(Response.new(code: 200, body: first_page.to_json, headers: {}))

    Provider::Powens.expects(:get)
      .with(
        "https://demo-sandbox.biapi.pro/2.0/users/me/accounts/11/transactions?page=2",
        has_entries(headers: { "Authorization" => "Bearer user-token" })
      )
      .returns(Response.new(code: 200, body: second_page.to_json, headers: {}))

    result = @provider.list_account_transactions("user-token", 11)

    assert_equal [ 1, 3 ], result[:transactions].map { |transaction| transaction[:id] }
  end

  test "raises typed errors for API failures" do
    Provider::Powens.expects(:post)
      .returns(Response.new(code: 401, body: { message: "Invalid token" }.to_json, headers: {}))

    error = assert_raises(Provider::Powens::PowensError) do
      @provider.create_user_token
    end

    assert_equal :invalid_token, error.error_type
    assert_equal 401, error.status
    assert_equal "Invalid token", error.message
  end
end

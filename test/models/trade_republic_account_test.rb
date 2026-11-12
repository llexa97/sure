require "test_helper"

class TradeRepublicAccountTest < ActiveSupport::TestCase
  PEA_NAME = "S&P 500 Swap Pea Eur (Acc)".freeze

  setup do
    @item = trade_republic_items(:configured_item)
    @item.trade_republic_accounts.destroy_all
    @portfolio = @item.trade_republic_accounts.create!(
      name: "Portfolio", kind: "portfolio", trade_republic_account_id: "DEPEA1", currency: "EUR"
    )
    @pea = @item.trade_republic_accounts.create!(
      name: "PEA", kind: "pea", trade_republic_account_id: "pea:DEPEA1", currency: "EUR"
    )
  end

  test "PEA orders are the orders of instruments bought through a PEA movement" do
    @portfolio.update!(raw_timeline_payload: [
      order("evt_pea", title: PEA_NAME, isin: "IE000DQLYVB9", quantity: "1", price: "6.5"),
      order("evt_cto", title: "Apple Inc.", isin: "US0378331005", quantity: "1", price: "150"),
      order("evt_btc", title: PEA_NAME, isin: "XF000BTC0017", quantity: "0.0001", price: "90000"),
      movement("evt_pea_in")
    ])

    assert_equal %w[evt_pea], @pea.reload.pea_order_events.map { |event| event["id"] }
  end

  test "PEA positions sum the orders and value them at the last order price" do
    @portfolio.update!(raw_timeline_payload: [
      order("evt_1", title: PEA_NAME, isin: "IE000DQLYVB9", quantity: "2", price: "6.40", timestamp: "2026-11-09T13:00:00Z"),
      order("evt_2", title: PEA_NAME, isin: "IE000DQLYVB9", quantity: "3", price: "6.60", timestamp: "2026-11-10T13:00:00Z"),
      order("evt_3", title: PEA_NAME, isin: "IE000DQLYVB9", quantity: "-1", price: "6.55", timestamp: "2026-11-08T13:00:00Z"),
      movement("evt_pea_in")
    ])

    position = @pea.reload.pea_positions.sole
    assert_equal "IE000DQLYVB9", position["isin"]
    assert_equal BigDecimal("4"), position["quantity"].to_d
    assert_equal BigDecimal("6.6"), position["price"].to_d
    assert_equal BigDecimal("26.4"), @pea.account_balance
  end

  test "a PEA account without PEA movements holds nothing" do
    @portfolio.update!(raw_timeline_payload: [
      order("evt_cto", title: "Apple Inc.", isin: "US0378331005", quantity: "1", price: "150")
    ])

    assert_empty @pea.reload.positions
    assert_equal 0, @pea.account_balance
  end

  test "a PEA links to investment accounts only" do
    assert @pea.linkable_to?(Account.new(accountable: Investment.new))
    assert_not @pea.linkable_to?(Account.new(accountable: Depository.new))
  end

  private

    def order(id, title:, isin:, quantity:, price:, timestamp: "2026-11-10T13:46:41Z")
      {
        "id" => id,
        "timestamp" => timestamp,
        "category" => "orderExecution",
        "eventType" => "TRADING_TRADE_EXECUTED",
        "title" => title,
        "detail" => {
          "isin" => isin,
          "name" => title,
          "quantity" => quantity,
          "price" => price,
          "amount" => (quantity.to_d.abs * price.to_d).to_s("F"),
          "currency" => "EUR"
        }
      }
    end

    def movement(id)
      {
        "id" => id,
        "timestamp" => "2026-11-10T13:46:43Z",
        "eventType" => "PEA_DEPOSIT_DEBIT",
        "title" => PEA_NAME,
        "subtitle" => "PEA",
        "detail" => { "amount" => -6.72, "signed_amount" => -6.72, "currency" => "EUR" }
      }
    end
end

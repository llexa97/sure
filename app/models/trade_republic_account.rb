class TradeRepublicAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include TradeRepublicAccount::DataHelpers

  if encryption_ready?
    encrypts :raw_positions_payload
    encrypts :raw_timeline_payload
  end

  belongs_to :trade_republic_item

  # The provider model can be loaded while Rails is booting before the
  # development schema cache has refreshed after a migration. Declaring the
  # type explicitly keeps the enum valid in that reload window as well.
  attribute :kind, :string, default: "portfolio"
  enum :kind, { portfolio: "portfolio", cash: "cash", crypto: "crypto", pea: "pea" }, default: :portfolio

  # Trade Republic lists crypto under pseudo-ISINs starting with XF000.
  CRYPTO_ISIN_PREFIX = "XF000"

  # A French PEA is a second securities account that Trade Republic neither
  # lists in the customer accounts nor returns in the portfolio snapshot. Its
  # orders share the main timeline, and every PEA order comes with a cash
  # movement into the PEA (PEA_DEPOSIT_DEBIT, PEA_SAVINGS_PLAN_PAY_IN) titled
  # with the instrument bought.
  PEA_EVENT_TYPE_PREFIX = "PEA_"
  ORDER_EXECUTION_CATEGORY = "orderExecution"

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :currency, presence: true
  validates :trade_republic_account_id, uniqueness: { scope: :trade_republic_item_id, allow_nil: true }

  def self.crypto_isin?(isin)
    isin.to_s.strip.upcase.start_with?(CRYPTO_ISIN_PREFIX)
  end

  def self.crypto_position?(position)
    return false unless position.is_a?(Hash)

    position = position.with_indifferent_access
    position[:category].to_s == "crypto_wallet" || crypto_isin?(position[:isin])
  end

  def self.pea_movement?(event)
    event.is_a?(Hash) && (event["eventType"] || event[:eventType]).to_s.start_with?(PEA_EVENT_TYPE_PREFIX)
  end

  # Instruments bought inside the PEA, named as the PEA cash movements title
  # them.
  def self.pea_instrument_names(events)
    Array(events).select { |event| pea_movement?(event) }
      .filter_map { |event| normalized_instrument_name(event["title"] || event[:title]) }
      .to_set
  end

  # An order executed inside the PEA: its instrument was bought through a PEA
  # cash movement. Crypto never trades in a PEA.
  def self.pea_order?(event, pea_names)
    return false unless event.is_a?(Hash) && pea_names.any?

    event = event.with_indifferent_access
    return false unless event[:category].to_s == ORDER_EXECUTION_CATEGORY

    detail = event[:detail].is_a?(Hash) ? event[:detail].with_indifferent_access : {}
    return false if crypto_isin?(detail[:isin])

    [ event[:title], detail[:name] ].any? { |name| pea_names.include?(normalized_instrument_name(name)) }
  end

  def self.normalized_instrument_name(name)
    name.to_s.squish.downcase.presence
  end

  def current_account
    account || linked_account
  end

  # The linked Sure account, unless it is being deleted or was disabled.
  def usable_account
    acct = current_account
    acct unless acct.nil? || acct.pending_deletion? || acct.disabled?
  end

  def sibling(kind)
    trade_republic_item.trade_republic_accounts.find_by(kind: kind)
  end

  # Manual accounts this provider account can be linked to. Crypto only
  # links to a Crypto exchange account, the Crypto subtype that supports
  # trades, or to an Investment account; Portfolio and Cash keep linking to
  # Investment and Depository accounts.
  def linkable_to?(account)
    case account.accountable_type
    when "Investment" then true
    when "Depository" then !crypto? && !pea?
    when "Crypto" then crypto? && account.accountable&.subtype == "exchange"
    else false
    end
  end

  # Portfolio, Crypto and PEA accounts hold securities; the Cash account
  # settles their trades.
  def holds_securities?
    portfolio? || crypto? || pea?
  end

  # Crypto moves to its own account once the user linked the Crypto account.
  # Until then the portfolio keeps holding it.
  def crypto_split?
    sibling("crypto")&.usable_account.present?
  end

  # PEA orders move to their own account once the user linked the PEA
  # account. Until then the portfolio keeps them.
  def pea_split?
    sibling("pea")&.usable_account.present?
  end

  # The PEA account stores no timeline of its own: it reads the PEA orders
  # from the portfolio's.
  def pea_order_events
    events = Array(pea? ? sibling("portfolio")&.raw_timeline_payload : raw_timeline_payload)
    names = self.class.pea_instrument_names(events)
    events.select { |event| self.class.pea_order?(event, names) }
  end

  # Trade Republic returns crypto in the portfolio snapshot. The Crypto
  # account holds those positions; the portfolio keeps them only while no
  # Crypto account is linked. The PEA has no snapshot, so its positions are
  # the sum of its orders.
  def positions
    case kind
    when "crypto"
      Array(sibling("portfolio")&.raw_positions_payload).select { |position| self.class.crypto_position?(position) }
    when "portfolio"
      positions = Array(raw_positions_payload)
      crypto_split? ? positions.reject { |position| self.class.crypto_position?(position) } : positions
    when "pea"
      pea_positions
    else
      []
    end
  end

  # The PEA positions are complete once the portfolio timeline they are
  # derived from was fetched in a complete sync.
  def positions_snapshot_complete?
    crypto? || pea? ? sibling("portfolio")&.holdings_snapshot_complete? : holdings_snapshot_complete?
  end

  # current_balance on the portfolio values the whole snapshot, crypto
  # included, so a split portfolio leaves out what the Crypto account holds.
  def account_balance
    return pea_positions_value if pea?
    return current_balance unless portfolio? && crypto_split?

    (current_balance || 0).to_d - (sibling("crypto").current_balance || 0).to_d
  end

  # Quantity held per ISIN from the PEA orders (signed: sells are negative),
  # valued at the latest known price (see pea_position_price).
  def pea_positions
    orders = pea_order_events.filter_map do |event|
      event = event.with_indifferent_access
      detail = event[:detail].is_a?(Hash) ? event[:detail].with_indifferent_access : {}
      quantity = parse_decimal(detail[:quantity])
      next if detail[:isin].blank? || quantity.nil? || quantity.zero?

      { event: event, detail: detail, quantity: quantity, time: Time.zone.parse(event[:timestamp].to_s) }
    rescue ArgumentError
      nil
    end

    orders.group_by { |order| order[:detail][:isin].to_s }.filter_map do |isin, isin_orders|
      quantity = isin_orders.sum { |order| order[:quantity] }
      next unless quantity.positive?

      last = isin_orders.max_by { |order| order[:time] || Time.zone.at(0) }
      price, price_date = pea_position_price(last)
      next unless price&.positive?

      {
        "isin" => isin,
        "name" => last[:detail][:name].presence || last[:event][:title],
        "symbol" => last[:detail][:symbol],
        "exchange_slug" => last[:detail][:exchange_slug],
        "quantity" => quantity.to_s("F"),
        "price" => price.to_s("F"),
        "price_date" => price_date&.iso8601,
        "category" => "brokerage"
      }
    end
  end

  def pea_positions_value
    pea_positions.sum(0.to_d) { |position| position["quantity"].to_d * position["price"].to_d }
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "TradeRepublicAccount", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload_account_provider
    provider
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "TradeRepublicAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "trade_republic",
      family: trade_republic_item.family,
      provider_key: "trade_republic"
    )
    nil
  end

  private

    # The instrument's latest market price when it is newer than the last
    # order, the price of that order otherwise.
    def pea_position_price(last_order)
      order_price = parse_decimal(last_order[:detail][:price])
      order_date = last_order[:time]&.to_date
      market = latest_market_price(last_order[:event][:id], after: order_date)
      market ? [ market.price.to_d, market.date ] : [ order_price, order_date ]
    end

    # The security Sure resolved for the order's trade, on whichever Trade
    # Republic account imported it.
    def latest_market_price(event_id, after:)
      return nil if event_id.blank? || after.nil?

      account_ids = trade_republic_item.trade_republic_accounts.filter_map { |tr_account| tr_account.current_account&.id }
      trade_entry = Entry.where(
        account_id: account_ids,
        source: "trade_republic",
        entryable_type: "Trade",
        external_id: "trade_republic_event_#{event_id}"
      ).first
      security = trade_entry&.entryable&.security
      return nil unless security

      price = security.prices.where("date > ?", after).where(currency: currency).order(date: :desc).first
      price if price&.price.to_d.positive?
    end
end

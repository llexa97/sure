# frozen_string_literal: true

# Processes Kraken Ledger entries (deposits, withdrawals, staking rewards, Earn
# income, standalone fees) stored in KrakenAccount#raw_transactions_payload["ledgers"].
#
# Kraken TradesHistory already handles spot buy/sell trades; ledger entries with
# type="trade" are therefore skipped here to avoid double-counting.  Internal
# sub-account transfers (type="transfer") and margin events (type="margin",
# "rollover", "settled") are also skipped.
#
# Fiat entries are cash and become Transactions, with Sure's sign convention:
# negative = inflow/income, positive = outflow/expense, so deposits and rewards
# are negative and withdrawals and fees positive.
#
# Crypto entries are not cash. They move units, so they become Trades carrying a
# quantity and the price on the day, with a zero amount -- see
# process_crypto_ledger_entry.
class KrakenAccount::LedgerProcessor
  include KrakenAccount::UsdConverter

  # Ledger types we import. `spend` and `receive` are the halves of Buy/Convert
  # purchases, recurring buys, baskets and the dust sweep ("convert small
  # balances"). A fiat/crypto group becomes Buy/Sell trades (see
  # process_conversions); what remains moves units like any other entry. Left
  # out they were not skipped but dropped, silently, by the guard below, so a
  # swept position stayed on the books at its pre-sweep quantity forever.
  SUPPORTED_TYPES = %w[deposit withdrawal staking earn fee spend receive].freeze

  # Types whose fee is charged on top of a movement with an external counterparty,
  # and so must stay a separate entry for transfer matching to work.
  SPLIT_FEE_TYPES = %w[deposit withdrawal].freeze

  # Ledger types we intentionally ignore (handled elsewhere or out of scope).
  SKIP_TYPES = %w[trade transfer margin rollover settled adjustment].freeze

  # Kraken Earn internal subtypes that represent fund movements, not income.
  EARN_INTERNAL_SUBTYPES = %w[allocation deallocation].freeze

  def initialize(kraken_account)
    @kraken_account = kraken_account
    @normalizer = KrakenAccount::AssetNormalizer.new(raw_payload&.dig("asset_metadata") || {})
  end

  def process
    return unless account.present?

    # Idempotency: load existing Kraken *ledger* external IDs once and test
    # membership in memory, instead of an EXISTS query per ledger entry (a full
    # sync can carry up to ~10k entries — see MAX_LEDGER_PAGES in the importer).
    # Scoped to the kraken_ledger_ prefix so trade entries aren't loaded.
    # The name comes along so a principal already holding its fee can be told
    # from one still owed it, and a trade's price_missing flag so one recorded
    # before its price existed can be priced later -- all without a lookup per
    # ledger row. The flag lives on the trade, read here by subselect so this
    # stays one query on entries.
    existing = account.entries
                      .where(source: "kraken")
                      .where("external_id LIKE 'kraken_ledger_%'")
                      .pluck(:external_id, :name, :user_modified, :entryable_type,
                             Arel.sql("(SELECT trades.extra -> 'kraken' ->> 'price_missing' FROM trades " \
                                      "WHERE entries.entryable_type = 'Trade' AND trades.id = entries.entryable_id)"))
    @existing_external_ids = existing.map(&:first).to_set
    @existing_principals = existing.to_h { |external_id, *rest| [ external_id, rest ] }

    warm_crypto_prices

    # Ledger ids a conversion trade stands for; they are not imported again
    # one by one below.
    @consumed_ledger_ids = Set.new
    process_conversions

    raw_ledgers.each do |ledger_id, ledger|
      next if @consumed_ledger_ids.include?(ledger_id)

      process_ledger_entry(ledger_id, ledger)
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process ledger entry #{ledger_id}: #{e.message}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_account.kraken_item&.family,
        metadata: { ledger_id: ledger_id, error_class: e.class.name }
      )
    end
  end

  private

    attr_reader :kraken_account, :normalizer

    def account
      kraken_account.current_account
    end

    def target_currency
      kraken_account.kraken_item&.family&.currency
    end

    def raw_payload
      kraken_account.raw_payload
    end

    def raw_ledgers
      kraken_account.raw_transactions_payload&.dig("ledgers") || {}
    end

    # Buy/Convert, recurring buys and crypto baskets settle as `spend` and
    # `receive` rows sharing a refid rather than as `trade` rows, so
    # TradesHistory never sees them. When one side is fiat and the other
    # crypto, the group is a purchase or a sale and becomes Buy/Sell trades
    # carrying the cash that moved, exactly as a TradesHistory fill would.
    # Recorded leg by leg they were internal sweeps instead: the cost basis
    # vanished and the fiat leg read as a separate cash movement.
    # Crypto-for-crypto groups (dust conversion) stay as individual rows.
    def process_conversions
      groups = conversion_groups
      return if groups.empty?

      existing = account.entries
                        .where(source: "kraken", external_id: groups.flat_map { |group| group[:external_ids] })
                        .includes(:entryable)
                        .index_by(&:external_id)

      groups.each do |group|
        process_conversion(group, existing)
      rescue StandardError => e
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "error",
          message: "Failed to process conversion #{group[:refid]}: #{e.message}",
          source: self.class.name,
          provider_key: "kraken",
          family: kraken_account.kraken_item&.family,
          metadata: { refid: group[:refid], error_class: e.class.name }
        )
      end
    end

    # One fiat currency on one side, crypto on the other, every fiat row moving
    # the opposite way to every crypto row. Anything else is left to the
    # row-by-row import.
    def conversion_groups
      raw_ledgers
        .select { |_id, ledger| %w[spend receive].include?(ledger["type"].to_s.downcase) && ledger["refid"].present? }
        .group_by { |_id, ledger| ledger["refid"].to_s }
        .filter_map do |refid, rows|
          legs = rows.map { |ledger_id, ledger| conversion_leg(ledger_id, ledger) }
          fiat_legs, crypto_legs = legs.partition { |leg| leg[:fiat] }
          next if fiat_legs.empty? || crypto_legs.empty?
          next unless fiat_legs.map { |leg| leg[:symbol] }.uniq.one?

          fiat_types = fiat_legs.map { |leg| leg[:type] }.uniq
          crypto_types = crypto_legs.map { |leg| leg[:type] }.uniq
          next unless fiat_types.one? && crypto_types.one? && fiat_types != crypto_types

          crypto_legs.sort_by! { |leg| leg[:ledger_id] }
          external_ids = crypto_legs.map { |leg| conversion_external_id(refid, leg, crypto_legs.size) }
          {
            refid: refid, buy: fiat_types.first == "spend",
            fiat_legs: fiat_legs, crypto_legs: crypto_legs, external_ids: external_ids
          }
        end
    end

    def conversion_leg(ledger_id, ledger)
      normalized = normalizer.normalize(ledger["asset"].to_s)
      {
        ledger_id: ledger_id, ledger: ledger, type: ledger["type"].to_s.downcase,
        symbol: normalized[:symbol], price_symbol: normalized[:price_symbol],
        fiat: fiat?(normalized[:price_symbol]),
        net: ledger["amount"].to_d - ledger["fee"].to_d
      }
    end

    # A single purchase keeps the bare refid, the id conversions were first
    # imported under; a basket needs one id per asset it bought or sold.
    def conversion_external_id(refid, crypto_leg, crypto_leg_count)
      return "kraken_conversion_#{refid}" if crypto_leg_count == 1

      "kraken_conversion_#{refid}_#{crypto_leg[:ledger_id]}"
    end

    # A basket's fiat legs carry no link to the asset each one paid for, so
    # the group's cash is shared equally between the assets it moved -- what a
    # basket of equal slices does, and the total stays exact either way.
    def process_conversion(group, existing)
      crypto_legs = group[:crypto_legs].reject { |leg| leg[:net].abs.round(8).zero? }
      return if crypto_legs.empty?

      securities = crypto_legs.to_h { |leg| [ leg[:ledger_id], resolve_security(leg[:price_symbol]) ] }
      # Without a security for every asset the group stays row by row, so no
      # unit goes unrecorded.
      return if securities.values.any?(&:nil?)

      fiat_legs = group[:fiat_legs]
      currency = fiat_legs.first[:symbol]
      cash_total = -fiat_legs.sum { |leg| leg[:net] }
      gross_total = fiat_legs.sum { |leg| leg[:ledger]["amount"].to_d.abs }
      fee_total = fiat_legs.sum { |leg| leg[:ledger]["fee"].to_d }

      cash_shares = split_evenly(cash_total, crypto_legs.size, entry_amount_scale)
      gross_shares = split_evenly(gross_total, crypto_legs.size, 8)
      fee_shares = split_evenly(fee_total, crypto_legs.size, trade_fee_scale)

      Entry.transaction do
        crypto_legs.each_with_index do |leg, index|
          upsert_conversion_trade(
            external_id: conversion_external_id(group[:refid], leg, group[:crypto_legs].size),
            existing: existing, group: group, leg: leg, security: securities[leg[:ledger_id]],
            currency: currency, cash: cash_shares[index], gross: gross_shares[index], fee: fee_shares[index]
          )
        end

        (fiat_legs + group[:crypto_legs]).each { |leg| remove_conversion_leg_row(leg[:ledger_id]) }
      end

      (fiat_legs + group[:crypto_legs]).each { |leg| @consumed_ledger_ids << leg[:ledger_id] }
    end

    def upsert_conversion_trade(external_id:, existing:, group:, leg:, security:, currency:, cash:, gross:, fee:)
      qty = leg[:net].abs.round(8)
      label = group[:buy] ? "Buy" : "Sell"
      attributes = {
        name: "#{label} #{qty.to_s('F').sub(/\.?0+\z/, '')} #{leg[:symbol]}",
        amount: cash,
        currency: currency,
        date: Time.zone.at(leg[:ledger]["time"].to_d).to_date
      }
      trade_attributes = {
        security: security,
        qty: group[:buy] ? qty : -qty,
        price: (gross / qty).round(trade_price_scale),
        currency: currency,
        fee: fee,
        investment_activity_label: label,
        extra: {
          "kraken" => {
            "refid" => group[:refid],
            "crypto_ledger_id" => leg[:ledger_id],
            "fiat_ledger_ids" => group[:fiat_legs].map { |fiat_leg| fiat_leg[:ledger_id] }.sort
          }
        }
      }

      entry = existing[external_id]
      if entry.nil?
        account.entries.create!(
          **attributes, external_id: external_id, source: "kraken",
          entryable: Trade.new(**trade_attributes)
        )
      elsif !entry.protected_from_sync? && entry.entryable.is_a?(Trade)
        # Conversions imported by an earlier version carry a buy as an inflow
        # and leave the fee out of the cash; they are rewritten in place.
        entry.entryable.update!(trade_attributes)
        entry.update!(attributes)
      end
    end

    # The leg was imported on its own before it was recognised as part of a
    # conversion; the trade now carries it. A row someone edited or matched
    # into a transfer is theirs and stays.
    def remove_conversion_leg_row(ledger_id)
      external_id = "kraken_ledger_#{ledger_id}"
      return unless @existing_external_ids.include?(external_id)

      entry = find_entry(external_id)
      return if entry.nil? || entry.protected_from_sync?
      return if entry.entryable.is_a?(Transaction) && in_transfer?(entry.entryable)

      entry.destroy!
      @existing_external_ids.delete(external_id)
      @existing_principals.delete(external_id)
    end

    # Shares rounded to the column's scale, the remainder on the last one, so
    # they always add back up to the total.
    def split_evenly(total, count, scale)
      share = (total / count).round(scale)
      Array.new(count - 1, share) + [ total - share * (count - 1) ]
    end

    def entry_amount_scale
      Entry.columns_hash["amount"].scale
    end

    def trade_fee_scale
      Trade.columns_hash["fee"].scale
    end

    def trade_price_scale
      Trade.columns_hash["price"].scale
    end

    def process_ledger_entry(ledger_id, ledger)
      type    = ledger["type"].to_s.downcase
      subtype = ledger["subtype"].to_s.downcase

      return if SKIP_TYPES.include?(type)
      return unless SUPPORTED_TYPES.include?(type)

      # Skip Earn allocation/deallocation — these are internal fund movements, not income.
      return if type == "earn" && EARN_INTERNAL_SUBTYPES.include?(subtype)

      external_id = "kraken_ledger_#{ledger_id}"
      raw_asset  = ledger["asset"].to_s
      raw_amount = ledger["amount"].to_d
      raw_fee    = ledger["fee"].to_d
      date       = Time.zone.at(ledger["time"].to_d).to_date

      # Kraken applies amount - fee to the balance, and reports the two separately.
      # Deposits and withdrawals are emitted as two entries so the movement keeps the
      # figure the counterparty actually sees: a bank records the transfer net of
      # Kraken's fee, and Transfer requires both legs to sum to zero, so folding the
      # fee in here makes the entry permanently unmatchable. Other ledger types have
      # no counterparty to reconcile against and keep the combined figure.
      normalized  = normalizer.normalize(raw_asset)
      symbol      = normalized[:symbol]
      base_symbol = normalized[:price_symbol]
      fiat        = fiat?(base_symbol)

      # Already in, and nothing more to add for it. Two exceptions: a split-fee
      # type, whose second entry may still be owed and is checked once the fee
      # is known; and a crypto row still in an older shape -- a cash Transaction
      # from before coin movements were trades, or a trade saved without a
      # price -- which the sync heals whatever the ledger type.
      if @existing_external_ids.include?(external_id) && !SPLIT_FEE_TYPES.include?(type)
        return if fiat || !crypto_row_needs_healing?(external_id)
      end

      # A crypto fee is paid in the units themselves, so it only reduces the
      # quantity; there is no second cash movement to split out.
      split_fee = fiat && SPLIT_FEE_TYPES.include?(type) && !raw_fee.zero?
      net        = raw_amount - raw_fee
      abs_impact = split_fee ? raw_amount.abs : net.abs

      # A crypto row has no fee half to owe, so a quantity of nothing -- a
      # correction row, a movement the fee consumed whole, or a reward below
      # the eight decimals trades.qty holds -- has nothing to record.
      unless fiat
        return if abs_impact.round(8).zero?

        process_crypto_ledger_entry(
          external_id: external_id, ledger_id: ledger_id, ledger: ledger, type: type,
          raw_asset: raw_asset, base_symbol: base_symbol, symbol: symbol,
          qty: abs_impact, outflow: net.negative?, date: date
        )
        return
      end

      # The principal is in from an earlier pass, or there is none: a correction
      # row can carry a fee against a zero amount. Either way the fee is checked
      # on its own external_id, so a later sync can still create the missing
      # half -- pricing it can fail on one sync and succeed on the next --
      # without duplicating the one it has.
      if abs_impact.zero? || @existing_external_ids.include?(external_id)
        if split_fee && !@existing_external_ids.include?("#{external_id}_fee") &&
           principal_awaits_fee?(external_id, raw_amount, symbol)
          process_ledger_fee(external_id, ledger_id, ledger, raw_fee, symbol, date)
        end
        return
      end

      entry_amount, price_missing = resolve_amount(abs_impact, symbol, date)
      return if entry_amount.nil?

      # Sure sign convention: inflow = negative, outflow = positive.
      signed_amount = inflow?(type) ? -entry_amount.abs : entry_amount.abs

      name  = build_name(type, abs_impact, symbol)
      label = activity_label(type)
      kind  = transaction_kind(type)
      extra = build_extra(ledger_id, ledger, raw_asset, price_missing)

      account.entries.create!(
        date: date,
        name: name,
        amount: signed_amount,
        currency: target_currency,
        external_id: external_id,
        source: "kraken",
        entryable: Transaction.new(
          kind: kind,
          investment_activity_label: label,
          extra: extra
        )
      )

      @existing_external_ids << external_id

      process_ledger_fee(external_id, ledger_id, ledger, raw_fee, symbol, date) if split_fee
    end

    # Crypto moves units, not cash. A staking reward does not put euros in the
    # account -- it puts coins in it -- and a deposit or withdrawal of coin is a
    # position change with no cash leg at all. Recorded as a Transaction the
    # quantity is lost entirely, so Holding::ReverseCalculator has nothing to
    # reverse and carries today's position backwards through history, while the
    # cash balance moves by an amount that never existed.
    #
    # `amount` is deliberately zero: Balance::BaseCalculator classifies a trade by
    # its amount regardless of label, so anything else would reintroduce the
    # phantom cash. The units and their price carry the value instead.
    def process_crypto_ledger_entry(external_id:, ledger_id:, ledger:, type:, raw_asset:, base_symbol:, symbol:, qty:, outflow:, date:)
      # A crypto row carries its fee inside the quantity, so once it is in there
      # is no second half owed. The caller's early return lets deposits and
      # withdrawals through for the fee a fiat row may still need, which would
      # otherwise bring this one back every sync -- unless what is in is the old
      # shape, which a sync should heal rather than keep.
      legacy = nil
      legacy_fee = nil
      if @existing_external_ids.include?(external_id)
        return reprice_crypto_trade(external_id, base_symbol, date) if unpriced_trade?(external_id)

        legacy = legacy_crypto_transaction(external_id)
        return if legacy.nil?

        # Before fees stayed inside a coin's quantity, a crypto deposit or
        # withdrawal with a fee was written as two cash rows. The trade that
        # replaces the principal already nets the fee, so the fee row would be
        # left describing money that never moved; it goes with the principal,
        # under the same rule -- edited or matched into a transfer, it stays.
        legacy_fee = legacy_crypto_transaction("#{external_id}_fee")
      end

      # Resolved before anything is removed: a symbol this cannot place must
      # leave the old row standing rather than take it away and put nothing back.
      security = resolve_security(base_symbol)
      return unless security

      price, price_missing = unit_price_on(security, base_symbol, date)
      # The direction comes from the ledger's own signed figure, not from the
      # type: a reversed withdrawal arrives, an earn migration leg can leave,
      # and on a trade a wrong sign moves units the wrong way through every
      # earlier holding. For a row that moves the way its type says, the two
      # agree.
      signed_qty = outflow ? -qty.abs : qty.abs

      Entry.transaction do
        legacy&.destroy!
        legacy_fee&.destroy!
        create_crypto_trade(external_id, ledger_id, ledger, type, raw_asset, symbol, qty, signed_qty, security, price, price_missing, date)
      end

      @existing_external_ids.delete("#{external_id}_fee") if legacy_fee
      @existing_external_ids << external_id
      @existing_principals[external_id] = [ build_name(type, qty, symbol), false, "Trade" ]
    end

    def create_crypto_trade(external_id, ledger_id, ledger, type, raw_asset, symbol, qty, signed_qty, security, price, price_missing, date)
      account.entries.create!(
        date: date,
        name: build_name(type, qty, symbol),
        amount: 0,
        currency: target_currency,
        external_id: external_id,
        source: "kraken",
        entryable: Trade.new(
          security: security,
          qty: signed_qty,
          price: price,
          currency: target_currency,
          investment_activity_label: crypto_activity_label(type),
          extra: build_extra(ledger_id, ledger, raw_asset, price_missing)
        )
      )
    end

    # An account synced before crypto rows became trades holds this row as a
    # Transaction: a cash movement that never happened, carrying a quantity the
    # holdings never saw. Replaced on the next sync, so an install does not have
    # to re-import to be right -- unless somebody has edited the row or matched
    # it into a transfer, in which case it is theirs and stays. Only a legacy
    # row costs a query; a Trade is already the new shape and answers from the
    # preload.
    def legacy_crypto_transaction(external_id)
      return nil unless legacy_crypto_candidate?(external_id)

      entry = find_entry(external_id)
      return nil if entry.nil? || in_transfer?(entry.entryable)

      entry
    end

    # Answered from the preload; the row itself is only read when it is one.
    def legacy_crypto_candidate?(external_id)
      _name, user_modified, entryable_type = @existing_principals[external_id]
      entryable_type == "Transaction" && !user_modified
    end

    def unpriced_trade?(external_id)
      _name, user_modified, entryable_type, price_missing = @existing_principals[external_id]
      entryable_type == "Trade" && price_missing == "true" && !user_modified
    end

    def crypto_row_needs_healing?(external_id)
      unpriced_trade?(external_id) || legacy_crypto_candidate?(external_id)
    end

    def find_entry(external_id)
      account.entries.includes(:entryable).find_by(external_id: external_id)
    end

    # A trade recorded before its price existed carries zero and the flag.
    # Pricing can fail on one sync and succeed on the next, so it is tried
    # again here and the trade is completed once a price is found.
    def reprice_crypto_trade(external_id, base_symbol, date)
      entry = find_entry(external_id)
      return if entry.nil?

      price, price_missing = unit_price_on(entry.entryable.security, base_symbol, date)
      return if price_missing

      trade = entry.entryable
      extra = trade.extra.deep_dup
      extra["kraken"]&.delete("price_missing")
      trade.update!(price: price, extra: extra)
      @existing_principals[external_id][3] = nil
    end

    # A transfer records its two legs on its own row; the transaction's own
    # transfer_id is only set by some paths, so both are checked.
    def in_transfer?(transaction)
      return true if transaction.transfer_id.present?

      Transfer.where(inflow_transaction_id: transaction.id).or(Transfer.where(outflow_transaction_id: transaction.id)).exists?
    end

    # A coin arriving from outside has a cost nothing here knows, so it is a
    # Transfer and the basis becomes unknown from that date -- the same treatment
    # an inbound share transfer already gets. A reward is acquired at the market
    # price on the day, which is both its basis and the income it represents.
    def crypto_activity_label(type)
      case type
      when "deposit", "withdrawal" then Trade::TRANSFER_LABEL
      when "staking"               then "Dividend"
      when "earn"                  then "Interest"
      when "fee"                   then "Fee"
      # What reaches here is a crypto-for-crypto dust sweep, or a half whose
      # group could not be read as a purchase. Both halves are internal
      # movements, so neither invents a cost basis.
      when "spend"                 then "Sweep Out"
      when "receive"               then "Sweep In"
      end
    end

    def fiat?(base_symbol)
      KrakenAccount::FIAT_CURRENCIES.include?(KrakenAccount::SecurityResolver.canonical_asset(base_symbol))
    end

    # One bulk request per asset for the span the ledger covers, the same call
    # MarketDataImporter makes, so that the per-entry lookup below is a
    # database read. Left to find_or_fetch_price it was one provider request
    # per entry -- thousands on a first import.
    def warm_crypto_prices
      spans = {}
      raw_ledgers.each_value do |ledger|
        next unless SUPPORTED_TYPES.include?(ledger["type"].to_s.downcase)

        base_symbol = normalizer.normalize(ledger["asset"].to_s)[:price_symbol]
        next if base_symbol.blank? || fiat?(base_symbol)

        date = Time.zone.at(ledger["time"].to_d).to_date
        span = (spans[base_symbol] ||= [ date, date ])
        span[0] = date if date < span[0]
        span[1] = date if date > span[1]
      end

      spans.each do |base_symbol, (from, to)|
        security = resolve_security(base_symbol)
        security&.import_provider_prices(start_date: from, end_date: to)
      rescue StandardError => e
        Rails.logger.warn "KrakenAccount::LedgerProcessor - could not warm prices for #{base_symbol}: #{e.message}"
      end
    end

    def resolve_security(base_symbol)
      KrakenAccount::SecurityResolver.resolve(base_symbol)
    end

    # The price on the day the units moved, not the price today. Falls back to
    # the balance snapshot's price, which is what the whole processor used to
    # use, and flags the entry so the staleness is visible in `extra`.
    def unit_price_on(security, base_symbol, date)
      price = security.prices.find_by(date: date)
      if price&.price.present?
        converted = Money.new(price.price, price.currency).exchange_to(target_currency).amount
        return [ converted, false ]
      end

      [ spot_price_fallback(base_symbol, date), true ]
    rescue StandardError
      [ spot_price_fallback(base_symbol, date), true ]
    end

    # The spot price as a last resort. It cannot be allowed to raise: it is
    # also what the rescue above reaches for, and an exception there would
    # escape it and lose the ledger row for this sync.
    def spot_price_fallback(base_symbol, date)
      fallback, = resolve_amount(1.to_d, base_symbol, date)
      fallback || 0
    rescue StandardError
      0
    end

    # Kraken's fee is always a cost, so it is an outflow whichever way the principal
    # moved. Its own external_id keeps it idempotent alongside the principal entry.
    # An entry written before fees were split holds the fee inside it: adding the
    # fee entry now would charge it twice. Only a principal already standing on
    # its own is owed one -- which happens when pricing the fee failed on an
    # earlier sync. The two are told apart by the native quantity the entry was
    # charged, which its name carries. Not by the stored amount: a crypto row is
    # converted at the current spot price, so recomputing it later scales the
    # candidates while the stored figure stays where it was, and after any real
    # price move nearness decides nothing.
    def principal_awaits_fee?(external_id, raw_amount, symbol)
      stored_name, user_modified = @existing_principals[external_id]
      return true if stored_name.nil? # no principal at all: a correction row carrying only a fee
      return false if user_modified

      charged = charged_quantity(stored_name, symbol)
      return false if charged.nil?

      charged == raw_amount.abs.round(8)
    end

    # The quantity out of "Withdrawal 0.501 BTC", compared as a number so a name
    # written when the formatting differed -- "500.0" against today's "500" --
    # still reads. Nil unless the name is one this class built for this symbol,
    # which leaves a renamed entry alone.
    def charged_quantity(name, symbol)
      parts = name.to_s.split(" ")
      return nil unless parts.length >= 3 && parts.last == symbol

      BigDecimal(parts[-2], exception: false)&.round(8)
    end

    def process_ledger_fee(principal_external_id, ledger_id, ledger, raw_fee, symbol, date)
      fee_external_id = "#{principal_external_id}_fee"
      return if @existing_external_ids.include?(fee_external_id)

      fee_amount, price_missing = resolve_amount(raw_fee.abs, symbol, date)
      return if fee_amount.nil? || fee_amount.zero?

      account.entries.create!(
        date: date,
        name: build_name("fee", raw_fee.abs, symbol),
        amount: fee_amount.abs,
        currency: target_currency,
        external_id: fee_external_id,
        source: "kraken",
        entryable: Transaction.new(
          kind: transaction_kind("fee"),
          investment_activity_label: activity_label("fee"),
          extra: build_extra(ledger_id, ledger, ledger["asset"].to_s, price_missing)
        )
      )

      @existing_external_ids << fee_external_id
    end

    # Returns [family_currency_amount, price_missing_bool] or [nil, nil] on hard failure.
    def resolve_amount(abs_impact, symbol, date)
      return [ abs_impact, false ] if symbol == target_currency

      if KrakenAccount::FIAT_CURRENCIES.include?(symbol)
        resolve_fiat_amount(abs_impact, symbol, date)
      else
        resolve_crypto_amount(abs_impact, symbol, date)
      end
    end

    def resolve_fiat_amount(abs_impact, symbol, date)
      if symbol == "USD"
        converted, stale, = convert_from_usd(abs_impact, date: date)
        return [ converted, stale ]
      end

      # Non-USD fiat: bridge through USD
      rate_to_usd = ExchangeRate.find_or_fetch_rate(from: symbol, to: "USD", date: date)
      return [ nil, nil ] unless rate_to_usd

      usd_amount = abs_impact * rate_to_usd.rate.to_d
      converted, stale, = convert_from_usd(usd_amount, date: date)
      [ converted, stale ]
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Fiat rate fetch failed for #{symbol}: #{e.message}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_account.kraken_item&.family,
        metadata: { symbol: symbol, date: date.to_s, error_class: e.class.name }
      )
      [ nil, nil ]
    end

    def resolve_crypto_amount(abs_impact, symbol, date)
      price_usd = stored_price_usd(symbol)

      if price_usd.nil?
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "warn",
          message: "No price available for #{symbol} on #{date}; amount recorded as 0",
          source: self.class.name,
          provider_key: "kraken",
          family: kraken_account.kraken_item&.family,
          metadata: { symbol: symbol, date: date.to_s }
        )
        return [ 0.to_d, true ]
      end

      usd_amount = abs_impact * price_usd
      converted, stale, = convert_from_usd(usd_amount, date: date)
      [ converted, stale ]
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Crypto price resolution failed for #{symbol}: #{e.message}",
        source: self.class.name,
        provider_key: "kraken",
        family: kraken_account.kraken_item&.family,
        metadata: { symbol: symbol, date: date.to_s, error_class: e.class.name }
      )
      [ 0.to_d, true ]
    end

    # Use the current spot price cached in raw_payload["assets"] by the Importer.
    # This is the price at last sync time, not at entry date — a best-effort
    # approximation; precise historical pricing is a future enhancement.
    def stored_price_usd(symbol)
      assets = raw_payload&.dig("assets") || []
      asset  = assets.find do |a|
        (a["symbol"] || a[:symbol]).to_s.upcase == symbol.upcase
      end
      price = asset&.dig("price_usd") || asset&.dig(:price_usd)
      price.present? ? price.to_d : nil
    end

    # True when the ledger event represents money flowing INTO the account.
    def inflow?(type)
      case type
      when "deposit", "staking", "earn", "receive" then true
      when "withdrawal", "fee", "spend"            then false
      else false
      end
    end

    def build_name(type, abs_impact, symbol)
      qty = abs_impact.to_d.round(8).to_s("F").sub(/\.?0+\z/, "")
      case type
      when "deposit"    then "Deposit #{qty} #{symbol}"
      when "withdrawal" then "Withdrawal #{qty} #{symbol}"
      when "staking"    then "Staking reward #{qty} #{symbol}"
      when "earn"       then "Earn reward #{qty} #{symbol}"
      when "fee"        then "Fee #{qty} #{symbol}"
      when "spend"      then "Converted #{qty} #{symbol}"
      when "receive"    then "Received #{qty} #{symbol}"
      else "#{type.capitalize} #{qty} #{symbol}"
      end
    end

    def activity_label(type)
      case type
      when "deposit"    then "Contribution"
      when "withdrawal" then "Withdrawal"
      when "staking"    then "Dividend"
      when "earn"       then "Interest"
      when "fee"        then "Fee"
      when "spend"      then "Sweep Out"
      when "receive"    then "Sweep In"
      end
    end

    def transaction_kind(type)
      case type
      when "deposit", "withdrawal" then "funds_movement"
      else "standard"
      end
    end

    def build_extra(ledger_id, ledger, raw_asset, price_missing)
      meta = {
        "ledger_id"  => ledger_id,
        "refid"      => ledger["refid"],
        "raw_asset"  => raw_asset,
        "raw_amount" => ledger["amount"],
        "fee_native" => ledger["fee"],
        "type"       => ledger["type"],
        "subtype"    => ledger["subtype"]
      }
      meta["price_missing"] = true if price_missing
      { "kraken" => meta }
    end
end

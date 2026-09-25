class UI::Account::PendingBalanceSummary < ApplicationComponent
  attr_reader :account

  def initialize(account:)
    @account = account
  end

  def render?
    pending_count.positive?
  end

  def pending_count
    pending_amounts.size
  end

  def pending_count_label
    I18n.t("UI.account.pending_balance_summary.pending_count", count: pending_count)
  end

  def balance_effect_money
    Money.new(balance_effect, account.currency)
  end

  def balance_effect_display
    money = balance_effect_money
    money.amount.positive? ? "+#{money.format}" : money.format
  end

  def estimated_balance_money
    account.balance_money + balance_effect_money
  end

  def effect_text_class
    return "text-secondary" if balance_effect.zero?

    favorable_effect? ? "text-success" : "text-warning"
  end

  private
    def pending_amounts
      @pending_amounts ||= account.entries
        .pending
        .where(excluded: false)
        .pluck(:amount)
    end

    # Sure stores expenses as positive entries and income as negative entries.
    # Assets therefore move in the opposite direction of the entry total,
    # while liabilities move in the same direction (a charge increases debt).
    def balance_effect
      @balance_effect ||= begin
        entry_total = pending_amounts.sum(0.to_d)
        account.liability? ? entry_total : -entry_total
      end
    end

    def favorable_effect?
      account.liability? ? balance_effect.negative? : balance_effect.positive?
    end
end

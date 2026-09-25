class BalanceSheet::AccountSubtypeGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :key, :name, :accounts

  def initialize(key:, name:, accounts:, account_group:)
    @key = key
    @name = name
    @accounts = accounts
    @account_group = account_group
  end

  def total
    accounts.sum(&:converted_balance)
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  def color
    account_group.color
  end

  def currency
    account_group.currency
  end

  private
    attr_reader :account_group
end

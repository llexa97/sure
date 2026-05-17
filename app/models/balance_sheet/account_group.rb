class BalanceSheet::AccountGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :name, :color, :accountable_type, :accounts

  def initialize(name:, color:, accountable_type:, accounts:, classification_group:)
    @name = name
    @color = color
    @accountable_type = accountable_type
    @accounts = accounts
    @classification_group = classification_group
  end

  # A stable DOM id for this group.
  # Example outputs:
  #   dom_id(tab: :asset)               # => "asset_depository"
  #   dom_id(tab: :all, mobile: true)   # => "mobile_all_depository"
  #
  # Keeping all of the logic here means the view layer and broadcaster only
  # need to ask the object for its DOM id instead of rebuilding string
  # fragments in multiple places.
  def dom_id(tab: nil, mobile: false)
    parts = []
    parts << "mobile" if mobile
    parts << (tab ? tab.to_s : classification.to_s)
    parts << key
    parts.compact.join("_")
  end

  def key
    accountable_type.to_s.underscore
  end

  def total
    accounts.sum(&:converted_balance)
  end

  def weight
    return 0 if classification_group.total.zero?

    total / classification_group.total.to_d * 100
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  def grouped_by_subtype?
    accounts.any? &&
      classification == "asset" &&
      accounts.all? { |account| account.balance_type == :cash } &&
      subtype_groups.many?
  end

  def subtype_groups
    @subtype_groups ||= accounts.group_by { |account| subtype_key(account) }
                                .map do |subtype, account_rows|
                                  BalanceSheet::AccountSubtypeGroup.new(
                                    key: subtype,
                                    name: account_rows.first.short_subtype_label,
                                    accounts: account_rows,
                                    account_group: self
                                  )
                                end
                                .sort_by { |group| subtype_sort_key(group.key, group.name) }
  end

  # "asset" or "liability"
  def classification
    classification_group.classification
  end

  def currency
    classification_group.currency
  end

  private
    UNGROUPED_SUBTYPE_KEY = "__ungrouped__"

    attr_reader :classification_group

    def subtype_key(account)
      account.subtype.presence || UNGROUPED_SUBTYPE_KEY
    end

    def subtype_sort_key(subtype, name)
      subtype_order = accountable_type.const_defined?(:SUBTYPES) ? accountable_type::SUBTYPES.keys : []
      [ subtype_order.index(subtype) || Float::INFINITY, name ]
    end
end

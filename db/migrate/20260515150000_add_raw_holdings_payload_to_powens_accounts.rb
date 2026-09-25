class AddRawHoldingsPayloadToPowensAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :powens_accounts, :raw_holdings_payload, :jsonb, default: {}
  end
end

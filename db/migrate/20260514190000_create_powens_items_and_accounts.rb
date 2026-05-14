class CreatePowensItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :powens_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :domain
      t.string :user_id
      t.text :access_token, null: false
      t.string :connection_id
      t.string :connector_id
      t.string :connector_uuid
      t.string :connector_name
      t.string :connector_color
      t.string :status, null: false, default: "good"
      t.string :connection_state
      t.string :reference, null: false
      t.datetime :access_expires_at
      t.datetime :last_synced_at
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.jsonb :raw_payload, default: {}
      t.jsonb :raw_connection_payload, default: {}
      t.timestamps
    end

    add_index :powens_items, :status
    add_index :powens_items, :connection_id, unique: true
    add_index :powens_items, :reference, unique: true

    create_table :powens_accounts, id: :uuid do |t|
      t.references :powens_item, null: false, foreign_key: true, type: :uuid
      t.string :account_id, null: false
      t.string :iban
      t.string :number
      t.string :name, null: false
      t.string :currency
      t.string :account_type
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.datetime :disabled_at
      t.datetime :deleted_at
      t.jsonb :institution_metadata, default: {}
      t.jsonb :raw_payload, default: {}
      t.jsonb :raw_transactions_payload, default: {}
      t.timestamps
    end

    add_index :powens_accounts, [ :powens_item_id, :account_id ], unique: true
  end
end

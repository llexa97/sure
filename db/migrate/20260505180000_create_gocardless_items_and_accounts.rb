class CreateGocardlessItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :gocardless_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :country_code
      t.string :institution_id, null: false
      t.string :institution_name
      t.string :institution_logo
      t.string :status, null: false, default: "good"
      t.string :agreement_id
      t.string :requisition_id, null: false
      t.string :reference
      t.datetime :access_expires_at
      t.datetime :last_synced_at
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.jsonb :raw_payload, default: {}
      t.jsonb :raw_institution_payload, default: {}
      t.timestamps
    end

    add_index :gocardless_items, :status
    add_index :gocardless_items, :requisition_id, unique: true
    add_index :gocardless_items, :reference

    create_table :gocardless_accounts, id: :uuid do |t|
      t.references :gocardless_item, null: false, foreign_key: true, type: :uuid
      t.string :account_id, null: false
      t.string :iban
      t.string :name, null: false
      t.string :currency
      t.string :account_type
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.jsonb :institution_metadata, default: {}
      t.jsonb :raw_payload, default: {}
      t.jsonb :raw_transactions_payload, default: {}
      t.timestamps
    end

    add_index :gocardless_accounts, [ :gocardless_item_id, :account_id ], unique: true
  end
end

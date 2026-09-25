require "test_helper"

class Family::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "syncs provider items and manual accounts" do
    family_sync = syncs(:family)
    @family.akahu_items.create!(
      name: "Test Akahu",
      app_token: "app_token",
      user_token: "user_token"
    )
    @family.gocardless_items.create!(
      name: "GoCardless Bank",
      institution_id: "REVOLUT_REVOGB21",
      requisition_id: SecureRandom.uuid
    )
    @family.powens_items.create!(
      name: "Powens Bank",
      access_token: "powens-token",
      reference: SecureRandom.uuid
    )

    manual_accounts_count = @family.accounts.manual.count
    syncer = Family::Syncer.new(@family)

    Account.any_instance
           .expects(:sync_later)
           .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
           .times(manual_accounts_count)

    syncable_item_associations.each do |association|
      association.klass.any_instance
                 .expects(:sync_later)
                 .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
                 .times(@family.public_send(association.name).syncable.count)
    end

    syncer.perform_sync(family_sync)

    assert_equal "completed", family_sync.reload.status
  end

  test "discovers syncable provider items through reflection" do
    association_names = syncable_item_associations.map(&:name)

    assert_includes association_names, :ibkr_items
    assert_includes association_names, :gocardless_items
    assert_includes association_names, :powens_items
  end

  test "syncs ibkr items through reflective provider discovery" do
    family_sync = syncs(:family)
    syncer = Family::Syncer.new(@family)

    Account.any_instance.stubs(:sync_later)
    syncable_item_associations.reject { |association| association.name == :ibkr_items }.each do |association|
      association.klass.any_instance.stubs(:sync_later)
    end

    IbkrItem.any_instance
            .expects(:sync_later)
            .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
            .times(@family.ibkr_items.syncable.count)

    syncer.perform_sync(family_sync)
  end

  test "only applies active rules during sync" do
    family_sync = syncs(:family)

    active_rule = @family.rules.create!(
      resource_type: "transaction",
      active: true,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    disabled_rule = @family.rules.create!(
      resource_type: "transaction",
      active: false,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    syncer = Family::Syncer.new(@family)

    @family.rules.stubs(:where).with(active: true).returns([ active_rule ])

    active_rule.expects(:apply_later).once
    disabled_rule.expects(:apply_later).never

    Account.any_instance.stubs(:sync_later)
    syncable_item_associations.each do |association|
      association.klass.any_instance.stubs(:sync_later)
    end

    syncer.perform_sync(family_sync)
    syncer.perform_post_sync
  end

  private
    def syncable_item_associations
      Family.reflect_on_all_associations(:has_many).select do |association|
        association.name.to_s.end_with?("_items") &&
          association.klass.included_modules.include?(Syncable)
      rescue NameError
        false
      end
    end
end

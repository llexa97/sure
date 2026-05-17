require "test_helper"

class Family::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "syncs provider items and manual accounts" do
    family_sync = syncs(:family)
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

    Family::Syncer::SYNCABLE_ITEM_ASSOCIATIONS.each do |association|
      item_class = @family.association(association).reflection.klass
      items_count = @family.public_send(association).syncable.count

      item_class.any_instance
                .expects(:sync_later)
                .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
                .times(items_count)
    end

    syncer.perform_sync(family_sync)

    assert_equal "completed", family_sync.reload.status
  end

  test "includes every syncable provider item association" do
    expected_associations = Family.reflect_on_all_associations(:has_many).filter_map do |association|
      next unless association.name.to_s.end_with?("_items")
      next unless association.klass.included_modules.include?(Syncable)
      next unless association.klass.respond_to?(:syncable)

      association.name
    rescue NameError
      nil
    end

    assert_equal expected_associations.sort, Family::Syncer::SYNCABLE_ITEM_ASSOCIATIONS.sort
  end

  test "only applies active rules during sync" do
    family_sync = syncs(:family)

    # Create an active rule
    active_rule = @family.rules.create!(
      resource_type: "transaction",
      active: true,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    # Create a disabled rule
    disabled_rule = @family.rules.create!(
      resource_type: "transaction",
      active: false,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    syncer = Family::Syncer.new(@family)

    # Stub the relation to return our specific instances so expectations work
    @family.rules.stubs(:where).with(active: true).returns([ active_rule ])

    # Expect apply_later to be called only for the active rule
    active_rule.expects(:apply_later).once
    disabled_rule.expects(:apply_later).never

    # Mock account and provider item syncs to avoid side effects
    Account.any_instance.stubs(:sync_later)
    Family::Syncer::SYNCABLE_ITEM_ASSOCIATIONS.each do |association|
      @family.association(association).reflection.klass.any_instance.stubs(:sync_later)
    end

    syncer.perform_sync(family_sync)
    syncer.perform_post_sync
  end
end

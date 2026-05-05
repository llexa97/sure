class GocardlessItem::SyncCompleteEvent
  attr_reader :gocardless_item

  def initialize(gocardless_item)
    @gocardless_item = gocardless_item
  end

  def broadcast
    gocardless_item.accounts.each(&:broadcast_sync_complete)
    gocardless_item.family&.broadcast_sync_complete
  end
end

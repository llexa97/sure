class PowensItem::SyncCompleteEvent
  attr_reader :powens_item

  def initialize(powens_item)
    @powens_item = powens_item
  end

  def broadcast
    powens_item.accounts.each(&:broadcast_sync_complete)
    powens_item.family&.broadcast_sync_complete
  end
end

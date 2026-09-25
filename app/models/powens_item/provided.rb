module PowensItem::Provided
  extend ActiveSupport::Concern

  def powens_provider
    Provider::PowensAdapter.build_provider
  end
end

Rails.application.configure do
  config.x.gocardless ||= ActiveSupport::OrderedOptions.new
  config.x.gocardless.include_pending = ENV["GOCARDLESS_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[1 true yes on])
end

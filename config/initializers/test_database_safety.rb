if Rails.env.test?
  Rails.application.config.after_initialize do
    db_name = ActiveRecord::Base.connection_db_config.database.to_s

    if db_name.match?(/prod|production/i)
      abort "Refusing to run tests against production-like database: #{db_name}"
    end
  end
end

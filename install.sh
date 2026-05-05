#!/usr/bin/env bash
set -euo pipefail

APP_USER="${APP_USER:-sure}"
APP_DIR="${APP_DIR:-/opt/sure}"
REPO_URL="${REPO_URL:-https://github.com/llexa97/sure.git}"
BRANCH="${BRANCH:-feature/gocardless-bank-sync}"
PORT="${PORT:-3000}"
RAILS_ENV="${RAILS_ENV:-production}"
DATABASE_URL="${DATABASE_URL:-}"
REDIS_URL="${REDIS_URL:-redis://127.0.0.1:6379/0}"

if [ -z "$DATABASE_URL" ]; then
  echo "ERROR: DATABASE_URL is required."
  echo "Example: sudo DATABASE_URL='postgresql://USER:PASSWORD@HOST:5432/DB' bash install.sh"
  echo "If your source URL uses SQLAlchemy's postgresql+asyncpg:// scheme, pass it as-is; this installer converts it for Rails."
  echo "Tip: do not commit or paste production database passwords into public repos."
  exit 1
fi

# Rails pg adapter expects postgresql://, while some tools provide postgresql+asyncpg://.
DATABASE_URL="${DATABASE_URL/postgresql+asyncpg:\/\//postgresql:\/\/}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root inside the LXC: sudo bash install.sh"
  exit 1
fi

apt-get update
apt-get install -y curl git build-essential autoconf bison rustc ca-certificates libssl-dev libreadline-dev zlib1g-dev libgmp-dev libncurses-dev libffi-dev libgdbm-dev libpq-dev pkg-config redis-server postgresql-client libyaml-dev libvips nodejs npm

npm install -g yarn >/dev/null 2>&1 || true

id "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$APP_USER"
mkdir -p "$APP_DIR"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

if [ ! -d "$APP_DIR/.git" ]; then
  sudo -u "$APP_USER" git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
else
  sudo -u "$APP_USER" git -C "$APP_DIR" fetch origin "$BRANCH"
  sudo -u "$APP_USER" git -C "$APP_DIR" checkout "$BRANCH"
  sudo -u "$APP_USER" git -C "$APP_DIR" pull --ff-only origin "$BRANCH"
fi

RUBY_VERSION="$(tr -d '[:space:]' < "$APP_DIR/.ruby-version")"
RBENV_ROOT="/home/$APP_USER/.rbenv"
if [ ! -d "$RBENV_ROOT" ]; then
  sudo -u "$APP_USER" git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
fi
if [ ! -d "$RBENV_ROOT/plugins/ruby-build" ]; then
  sudo -u "$APP_USER" mkdir -p "$RBENV_ROOT/plugins"
  sudo -u "$APP_USER" git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
else
  sudo -u "$APP_USER" git -C "$RBENV_ROOT/plugins/ruby-build" pull --ff-only
fi
sudo -u "$APP_USER" env RBENV_ROOT="$RBENV_ROOT" PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" rbenv install -s "$RUBY_VERSION"
sudo -u "$APP_USER" env RBENV_ROOT="$RBENV_ROOT" PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" rbenv global "$RUBY_VERSION"
sudo -u "$APP_USER" env RBENV_ROOT="$RBENV_ROOT" PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" gem install bundler --no-document

SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(sudo -u "$APP_USER" env RBENV_ROOT="$RBENV_ROOT" PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')}"

cat > "$APP_DIR/.env.production" <<ENV
RAILS_ENV=$RAILS_ENV
SELF_HOSTED=true
PORT=$PORT
DATABASE_URL=$DATABASE_URL
REDIS_URL=$REDIS_URL
SECRET_KEY_BASE=$SECRET_KEY_BASE
GOCARDLESS_ENABLED=${GOCARDLESS_ENABLED:-1}
GOCARDLESS_SECRET_ID=${GOCARDLESS_SECRET_ID:-}
GOCARDLESS_SECRET_KEY=${GOCARDLESS_SECRET_KEY:-}
GOCARDLESS_INCLUDE_PENDING=${GOCARDLESS_INCLUDE_PENDING:-false}
ENV
chown "$APP_USER:$APP_USER" "$APP_DIR/.env.production"
chmod 600 "$APP_DIR/.env.production"

sudo -u "$APP_USER" env RBENV_ROOT="$RBENV_ROOT" PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" bash -lc "cd '$APP_DIR' && bundle config set deployment 'true' && bundle config set without 'development test' && bundle install"
sudo -u "$APP_USER" env RBENV_ROOT="$RBENV_ROOT" PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" bash -lc "cd '$APP_DIR' && npm install"
sudo -u "$APP_USER" env RBENV_ROOT="$RBENV_ROOT" PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH" bash -lc "cd '$APP_DIR' && set -a && source .env.production && set +a && bundle exec rails db:migrate assets:precompile"

cat > /etc/systemd/system/sure.service <<SERVICE
[Unit]
Description=Sure Finance Rails app
After=network-online.target redis-server.service
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env.production
Environment=RBENV_ROOT=$RBENV_ROOT
Environment=PATH=$RBENV_ROOT/bin:$RBENV_ROOT/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash -lc 'exec bundle exec puma -C config/puma.rb'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

cat > /etc/systemd/system/sure-sidekiq.service <<SERVICE
[Unit]
Description=Sure Finance Sidekiq
After=network-online.target redis-server.service
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env.production
Environment=RBENV_ROOT=$RBENV_ROOT
Environment=PATH=$RBENV_ROOT/bin:$RBENV_ROOT/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash -lc 'exec bundle exec sidekiq'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now redis-server sure.service sure-sidekiq.service
systemctl --no-pager --full status sure.service | sed -n '1,16p'
echo "Sure installed. URL: http://$(hostname -I | awk '{print $1}'):$PORT"
echo "Configure GoCardless secrets in $APP_DIR/.env.production or Settings > Providers, then restart: systemctl restart sure sure-sidekiq"

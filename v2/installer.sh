#!/usr/bin/env bash
# =============================================================================
# Actools Drupal 11 Multi-Environment Installer – Enterprise v3 (Ubuntu 24.04)
# =============================================================================

set -euo pipefail

# ─── CONFIG PATHS ────────────────────────────────────────────────────────────
LOG_FILE="$HOME/actools-install.log"
ENV_FILE="$HOME/actools.env"
STATE_FILE="$HOME/.actools-state.json"
LOCK_FILE="/tmp/actools.lock"

# ─── LOGGING ─────────────────────────────────────────────────────────────────
log() { echo "[$1] $(date '+%Y-%m-%d %H:%M:%S') ${*:2}" | tee -a "$LOG_FILE"; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; exit 1; }

# ─── MODES ───────────────────────────────────────────────────────────────────
MODE="${1:-fresh}"
[[ "${2:-}" == "--force" ]] && FORCE=true || FORCE=false

info "Actools installer started (mode: $MODE)"

# ─── SECURITY ────────────────────────────────────────────────────────────────
[[ "$(id -u)" == "0" ]] && error "Do NOT run as root"
[[ -z "${SUDO_USER:-}" ]] && error "Run with sudo"

if who | grep -q "$(whoami).*(:0|pts/0)"; then
  error "Password/console login detected. Use SSH key."
fi

# Passwordless sudo
SUDO_LINE="$SUDO_USER ALL=(ALL) NOPASSWD:ALL"
if ! sudo grep -qxF "$SUDO_LINE" "/etc/sudoers.d/$SUDO_USER" 2>/dev/null; then
  echo "$SUDO_LINE" | sudo tee "/etc/sudoers.d/$SUDO_USER" >/dev/null
  sudo chmod 440 "/etc/sudoers.d/$SUDO_USER"
  info "Enabled passwordless sudo"
fi

# OS check
lsb_release -cs | grep -q noble || error "Ubuntu 24.04 required"

# Lock
[[ -f "$LOCK_FILE" ]] && error "Another run in progress"
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ─── PACKAGES ────────────────────────────────────────────────────────────────
info "Installing base packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq curl git unzip zip gnupg lsb-release \
  build-essential software-properties-common acl vim htop jq

# Docker
if ! command -v docker &>/dev/null; then
  info "Installing Docker..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

sudo usermod -aG docker "$SUDO_USER" || true

# PHP
if ! php -v | grep -q "8.4"; then
  info "Installing PHP 8.4..."
  sudo add-apt-repository ppa:ondrej/php -y
  sudo apt-get update -qq
  sudo apt-get install -y -qq php8.4 php8.4-fpm php8.4-cli php8.4-mysql \
    php8.4-xml php8.4-mbstring php8.4-curl php8.4-zip php8.4-gd \
    php8.4-intl php8.4-bcmath php8.4-opcache php8.4-apcu \
    php8.4-redis php8.4-imagick php8.4-dev
fi

# Composer
if ! command -v composer &>/dev/null; then
  info "Installing Composer..."
  curl -sS https://getcomposer.org/installer -o composer-setup.php
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm composer-setup.php
fi

# Node
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -
  sudo apt-get install -y -qq nodejs
  sudo corepack enable
fi

# ─── CONFIG ──────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || error "Missing $ENV_FILE"
source "$ENV_FILE"

: "${BASE_DOMAIN:?Missing BASE_DOMAIN}"
: "${DRUPAL_ADMIN_EMAIL:?Missing DRUPAL_ADMIN_EMAIL}"
: "${DB_ROOT_PASS:?Missing DB_ROOT_PASS}"

# ─── STATE INIT ──────────────────────────────────────────────────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{"installed":false,"environments":{},"db_creds":{}}' > "$STATE_FILE"
fi

# ─── HELPERS ─────────────────────────────────────────────────────────────────
rand_pass() { openssl rand -base64 18 | tr -dc A-Za-z0-9 | head -c 20; }

get_db_pass() {
  jq -r ".db_creds.$1.pass // empty" "$STATE_FILE"
}

set_db_pass() {
  local env="$1" pass="$2"
  tmp=$(mktemp)
  jq ".db_creds.$env = {user: \"actools_$env\", pass: \"$pass\"}" "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

mark_installed() {
  tmp=$(mktemp)
  jq ".environments.$1 = true" "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

is_installed() {
  jq -e ".environments.$1 == true" "$STATE_FILE" >/dev/null
}

wait_db() {
  info "Waiting for DB..."
  for i in {1..30}; do
    if docker compose exec -T db mysqladmin ping -h localhost --silent; then
      return
    fi
    sleep 2
  done
  error "DB not ready"
}

backup_env() {
  local env="$1"
  local dir="/var/www/html/$env"
  local backup_dir="$HOME/actools_backups/$(date +%F_%H%M%S)/$env"
  mkdir -p "$backup_dir"

  info "Backing up $env"

  CONTAINER_PHP=$(docker compose ps -q php)

  docker compose exec -T php drush @$env sql-dump --gzip --result-file=/tmp/db.sql.gz || true
  docker cp "$CONTAINER_PHP":/tmp/db.sql.gz "$backup_dir/database.sql.gz" || true
  docker compose exec -T php rm -f /tmp/db.sql.gz || true

  if docker compose exec -T php test -d "$dir/web/sites/default/files"; then
    docker compose exec -T php tar -czf /tmp/files.tar.gz -C "$dir/web/sites/default" files
    docker cp "$CONTAINER_PHP":/tmp/files.tar.gz "$backup_dir/files.tar.gz"
    docker compose exec -T php rm -f /tmp/files.tar.gz
  fi

  find "$HOME/actools_backups" -type d -mtime +7 -exec rm -rf {} +
}

# ─── DOCKER SETUP ────────────────────────────────────────────────────────────
setup_docker() {

cat > docker-compose.yml <<EOF
services:
  caddy:
    image: caddy:2.8-alpine
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
    restart: unless-stopped

  php:
    image: drupal:11-php${PHP_VERSION}-fpm
    volumes:
      - ./docroot:/var/www/html

  db:
    image: mariadb:${MARIADB_VERSION}
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
    volumes:
      - db_data:/var/lib/mysql

  redis:
    image: redis:7-alpine

volumes:
  caddy_data:
  db_data:
EOF

cat > Caddyfile <<EOF
${BASE_DOMAIN}, dev.${BASE_DOMAIN}, stg.${BASE_DOMAIN} {

  @dev host dev.${BASE_DOMAIN}
  @stg host stg.${BASE_DOMAIN}
  @prod host ${BASE_DOMAIN}

  route @dev { root * /var/www/html/dev/web }
  route @stg { root * /var/www/html/stg/web }
  route @prod { root * /var/www/html/prod/web }

  php_fastcgi php:9000
  file_server
}
EOF

docker compose up -d
wait_db
}

# ─── INSTALL ENV ─────────────────────────────────────────────────────────────
install_env() {
  local env="$1"
  local db="actools_$env"

  if is_installed "$env"; then
    info "$env already installed, skipping"
    return
  fi

  if [[ "$MODE" == "rerun" && "$FORCE" == true ]]; then
    backup_env "$env"
  fi

  local db_pass
  db_pass=$(get_db_pass "$env")

  if [[ -z "$db_pass" ]]; then
    db_pass=$(rand_pass)
    set_db_pass "$env" "$db_pass"
  fi

  docker compose exec -T db mysql -uroot -p"$DB_ROOT_PASS" -e "
    CREATE DATABASE IF NOT EXISTS $db;
    CREATE USER IF NOT EXISTS '$db'@'%' IDENTIFIED BY '$db_pass';
    GRANT ALL ON $db.* TO '$db'@'%';
    FLUSH PRIVILEGES;
  "

  docker compose exec -T php bash -c "
    mkdir -p /var/www/html/$env
    cd /var/www/html/$env

    if [ ! -f composer.json ]; then
      composer create-project drupal/recommended-project:$DRUPAL_VERSION .
    fi

    composer install --no-dev

    if ! vendor/bin/drush status --field=bootstrap | grep -q Successful; then
      vendor/bin/drush site:install standard -y \
        --db-url=mysql://$db:$db_pass@db/$db \
        --account-mail=$DRUPAL_ADMIN_EMAIL
    fi
  "

  mark_installed "$env"
  info "$env installed"
}

# ─── HARDENING ───────────────────────────────────────────────────────────────
harden() {
  info "Applying permissions..."
  sudo chown -R www-data:www-data docroot
  sudo find docroot -type d -exec chmod 755 {} +
  sudo find docroot -type f -exec chmod 644 {} +
}

# ─── MAIN ────────────────────────────────────────────────────────────────────
main() {

info "===== ACTOOLS INSTALL ====="
info "Domain: $BASE_DOMAIN"
info "Mode: $MODE"

read -p "Proceed? [y/N] " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

[[ "$MODE" == "fresh" ]] && setup_docker

for env in dev stg prod; do
  install_env "$env"
done

harden

info "Done:"
info "https://$BASE_DOMAIN"
info "https://dev.$BASE_DOMAIN"
info "https://stg.$BASE_DOMAIN"
}

main "$@"

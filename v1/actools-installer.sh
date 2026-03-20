#!/usr/bin/env bash
# =============================================================================
# Actools Drupal 11 Multi-Environment Installer – Enterprise v2 (Ubuntu 24.04)
# =============================================================================

set -euo pipefail

# ─── Logging ─────────────────────────────────────────────────────────────────
LOG_FILE="$HOME/actools-install.log"
log() { echo "[$1] $(date '+%Y-%m-%d %H:%M:%S') ${*:2}" | tee -a "$LOG_FILE"; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; exit 1; }

info "Actools installer started (mode: ${1:-fresh})"

MODE="${1:-fresh}"
[[ "${2:-}" == "--force" ]] && FORCE=true || FORCE=false

ENV_FILE="$HOME/actools.env"
STATE_FILE="$HOME/.actools-state.json"
LOCK_FILE="/tmp/actools.lock"

# ─── Security ────────────────────────────────────────────────────────────────
[[ "$(id -u)" == "0" ]] && error "Do NOT run as root."
[[ -z "${SUDO_USER:-}" ]] && error "Run with sudo."

if who | grep -q "$(whoami).*(:0|pts/0)"; then
  error "Password login detected. Use SSH key."
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

# ─── Packages ────────────────────────────────────────────────────────────────
info "Installing base packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq curl git unzip zip gnupg lsb-release \
  build-essential software-properties-common acl vim htop

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

# ─── Config ──────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || error "Missing $ENV_FILE"
source "$ENV_FILE"

# Validate required vars
: "${BASE_DOMAIN:?Missing BASE_DOMAIN}"
: "${DRUPAL_ADMIN_EMAIL:?Missing DRUPAL_ADMIN_EMAIL}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
rand_pass() { openssl rand -base64 18 | tr -dc A-Za-z0-9 | head -c 20; }

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

# ─── Docker Setup ────────────────────────────────────────────────────────────
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

volumes:
  caddy_data:
  db_data:
EOF

cat > Caddyfile <<EOF
${BASE_DOMAIN}, dev.${BASE_DOMAIN}, stg.${BASE_DOMAIN} {
  root * /var/www/html/{host}/web
  php_fastcgi php:9000
  file_server
}
EOF

docker compose up -d
}

# ─── Drupal Install ──────────────────────────────────────────────────────────
install_env() {
  local env="$1"
  local db="actools_${env}"
  local db_pass
  db_pass=$(rand_pass)

  wait_db

  docker compose exec -T db mysql -uroot -p"$DB_ROOT_PASS" -e "
    CREATE DATABASE IF NOT EXISTS $db;
    CREATE USER IF NOT EXISTS '$db'@'%' IDENTIFIED BY '$db_pass';
    GRANT ALL ON $db.* TO '$db'@'%';
    FLUSH PRIVILEGES;
  "

  docker compose exec -T php bash -c "
    cd /var/www/html/$env || mkdir -p /var/www/html/$env && cd /var/www/html/$env

    if [ ! -f composer.json ]; then
      composer create-project drupal/recommended-project:$DRUPAL_VERSION .
    fi

    composer install --no-dev

    if ! vendor/bin/drush status | grep -q Successful; then
      vendor/bin/drush site:install standard -y \
        --db-url=mysql://$db:$db_pass@db/$db \
        --account-mail=$DRUPAL_ADMIN_EMAIL
    fi
  "

  info "$env installed"
}

# ─── Main ────────────────────────────────────────────────────────────────────
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

info "Done: https://$BASE_DOMAIN"
}

main "$@"

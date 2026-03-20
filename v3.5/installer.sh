#!/usr/bin/env bash
# =============================================================================
# Actools Enterprise v3.5 (Ubuntu 24.04)
# =============================================================================
# Hybrid architecture:
# - v3 safety (backup, lock, idempotency, routing)
# - v4 security (SSH-only, state-driven, DB isolation)
# - Production hardened
# =============================================================================

set -euo pipefail

# ───────────────── CONFIG ─────────────────
MODE="${1:-fresh}"
[[ "${2:-}" == "--force" ]] && FORCE=true || FORCE=false
DRY_RUN="${DRY_RUN:-false}"

ENV_FILE="$HOME/actools.env"
STATE_FILE="$HOME/.actools-state.json"
LOCK_FILE="/tmp/actools.lock"
LOG_FILE="$HOME/actools-install.log"

# ───────────────── LOGGING ─────────────────
log() { echo "[$1] $(date '+%F %T') ${*:2}" | tee -a "$LOG_FILE"; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; exit 1; }

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

info "Actools v3.5 started (mode=$MODE)"

# ───────────────── SECURITY BASELINE ─────────────────
[[ "$(id -u)" == "0" ]] && error "Do NOT run as root"
[[ -z "${SUDO_USER:-}" ]] && error "Run with sudo"

# Require SSH key
[[ ! -f "$HOME/.ssh/authorized_keys" ]] && error "No SSH keys found"
grep -q "ssh-" "$HOME/.ssh/authorized_keys" || error "SSH keys required"

# Passwordless sudo
SUDO_LINE="$SUDO_USER ALL=(ALL) NOPASSWD:ALL"
if ! sudo grep -qxF "$SUDO_LINE" "/etc/sudoers.d/$SUDO_USER" 2>/dev/null; then
  echo "$SUDO_LINE" | sudo tee "/etc/sudoers.d/$SUDO_USER" >/dev/null
  sudo chmod 440 "/etc/sudoers.d/$SUDO_USER"
fi

# OS check
lsb_release -cs | grep -q noble || error "Ubuntu 24.04 required"

# Lock
[[ -f "$LOCK_FILE" ]] && error "Another run in progress"
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ───────────────── CONFIG LOAD ─────────────────
[[ -f "$ENV_FILE" ]] || error "Missing $ENV_FILE"
source "$ENV_FILE"

: "${BASE_DOMAIN:?Missing BASE_DOMAIN}"
: "${DRUPAL_ADMIN_EMAIL:?Missing DRUPAL_ADMIN_EMAIL}"
: "${DB_ROOT_PASS:?Missing DB_ROOT_PASS}"

chmod 600 "$ENV_FILE"

# ───────────────── STATE ─────────────────
init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"envs":{},"db":{}}' > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  fi
}

get_db_pass() { jq -r ".db.$1.pass // empty" "$STATE_FILE"; }

set_db_pass() {
  tmp=$(mktemp)
  jq ".db.$1 = {user:\"actools_$1\",pass:\"$2\"}" "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

is_installed() { jq -e ".envs.$1 == true" "$STATE_FILE" >/dev/null 2>&1; }

mark_installed() {
  tmp=$(mktemp)
  jq ".envs.$1=true" "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

rand_pass() { openssl rand -base64 18 | tr -dc A-Za-z0-9 | head -c 20; }

# ───────────────── INSTALL BASE ─────────────────
install_base() {
  info "Installing base packages"
  run "sudo apt-get update -qq"
  run "sudo apt-get install -y -qq curl git unzip zip gnupg jq"
}

install_docker() {
  if ! command -v docker &>/dev/null; then
    info "Installing Docker"
    run "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg"
    run "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable\" | sudo tee /etc/apt/sources.list.d/docker.list"
    run "sudo apt-get update -qq"
    run "sudo apt-get install -y -qq docker-ce docker-compose-plugin"
  fi
  sudo usermod -aG docker "$SUDO_USER" || true
}

# ───────────────── STACK ─────────────────
setup_stack() {
cat > docker-compose.yml <<EOF
services:
  caddy:
    image: caddy:2.8-alpine
    ports: ["80:80","443:443"]
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

  encode zstd gzip
}
EOF

  docker compose up -d
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

# ───────────────── BACKUP ─────────────────
backup_env() {
  local env="$1"
  local dir="$HOME/actools_backups/$(date +%F_%H%M%S)/$env"
  mkdir -p "$dir"

  info "Backing up $env"

  CONTAINER=$(docker compose ps -q php)

  docker compose exec -T php drush @$env sql-dump --gzip --result-file=/tmp/db.sql.gz || true
  docker cp "$CONTAINER":/tmp/db.sql.gz "$dir/db.sql.gz" || true
  docker compose exec -T php rm -f /tmp/db.sql.gz || true

  if docker compose exec -T php test -d "/var/www/html/$env/web/sites/default/files"; then
    docker compose exec -T php tar -czf /tmp/files.tar.gz -C /var/www/html/$env/web/sites/default files
    docker cp "$CONTAINER":/tmp/files.tar.gz "$dir/files.tar.gz"
    docker compose exec -T php rm -f /tmp/files.tar.gz
  fi

  find "$HOME/actools_backups" -type d -mtime +7 -exec rm -rf {} +
}

# ───────────────── INSTALL ENV ─────────────────
install_env() {
  local env="$1"
  local db="actools_$env"

  if is_installed "$env" && [[ "$FORCE" != true ]]; then
    info "$env already installed — skipping"
    return
  fi

  if [[ "$FORCE" == true ]]; then
    warn "FORCE mode enabled"
    read -p "Type YES to destroy $env: " confirm
    [[ "$confirm" == "YES" ]] || exit 1
    backup_env "$env"
  fi

  local pass
  pass=$(get_db_pass "$env")
  [[ -z "$pass" ]] && pass=$(rand_pass) && set_db_pass "$env" "$pass"

  wait_db

  docker compose exec -T db mysql -uroot -p"$DB_ROOT_PASS" -e "
    CREATE DATABASE IF NOT EXISTS $db;
    CREATE USER IF NOT EXISTS '$db'@'%' IDENTIFIED BY '$pass';
    GRANT ALL ON $db.* TO '$db'@'%';
    FLUSH PRIVILEGES;
  "

  docker compose exec -T php bash -c "
    mkdir -p /var/www/html/$env && cd /var/www/html/$env

    [ ! -f composer.json ] && composer create-project drupal/recommended-project:$DRUPAL_VERSION .

    composer install --no-dev

    if ! vendor/bin/drush status --field=bootstrap | grep -q Successful; then
      vendor/bin/drush site:install standard -y \
        --db-url=mysql://$db:$pass@db/$db \
        --account-mail=$DRUPAL_ADMIN_EMAIL
    fi
  "

  mark_installed "$env"
  info "$env installed"
}

# ───────────────── HARDEN ─────────────────
harden() {
  info "Applying file permissions"
  sudo chown -R www-data:www-data docroot
  sudo find docroot -type d -exec chmod 755 {} +
  sudo find docroot -type f -exec chmod 644 {} +
}

# ───────────────── MAIN ─────────────────
main() {

init_state
install_base
install_docker

info "===== PRE-FLIGHT ====="
info "Domain: $BASE_DOMAIN"
info "Mode: $MODE"
info "DRY_RUN: $DRY_RUN"

read -p "Proceed? [y/N] " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

[[ "$MODE" == "fresh" ]] && setup_stack

for env in dev stg prod; do
  install_env "$env"
done

harden

info "Deployment complete:"
info "https://$BASE_DOMAIN"
info "https://dev.$BASE_DOMAIN"
info "https://stg.$BASE_DOMAIN"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Actools Enterprise Installer v3.11b (Ubuntu 24.04)
# =============================================================================

ACTOOLS_VERSION="3.11b"
MODE="${1:-fresh}"
FORCE=false
[[ "${2:-}" == "--force" ]] && FORCE=true
DRY_RUN="${DRY_RUN:-false}"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(eval echo ~$REAL_USER)"

ENV_FILE="$REAL_HOME/actools.env"
STATE_FILE="$REAL_HOME/.actools-state.json"
LOCK_FILE="/tmp/actools.lock"
LOG_FILE="$REAL_HOME/actools-install.log"

# =============================================================================
# LOGGING
# =============================================================================
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

info "Actools v$ACTOOLS_VERSION started (mode=$MODE)"

# =============================================================================
# SECURITY CHECKS
# =============================================================================
if [[ "$(id -u)" -ne 0 ]]; then
  error "Run with sudo"
fi
if [[ -z "${SUDO_USER:-}" ]]; then
  error "Do NOT run as root directly. Use sudo."
fi
[[ -s "$REAL_HOME/.ssh/authorized_keys" ]] || error "No SSH keys found for user $REAL_USER"

[[ -f "$LOCK_FILE" ]] && error "Another run in progress"
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

lsb_release -cs | grep -q noble || error "Ubuntu 24.04 required"

# =============================================================================
# LOAD ENV
# =============================================================================
[[ -f "$ENV_FILE" ]] || error "Missing $ENV_FILE"
source "$ENV_FILE"

: "${BASE_DOMAIN:?Missing BASE_DOMAIN}"
: "${DRUPAL_ADMIN_EMAIL:?Missing DRUPAL_ADMIN_EMAIL}"
: "${DB_ROOT_PASS:?Missing DB_ROOT_PASS}"
SECURITY_PROFILE="${SECURITY_PROFILE:-baseline}"
PHP_VERSION="${PHP_VERSION:-8.2}"
MARIADB_VERSION="${MARIADB_VERSION:-11.0}"
DRUPAL_VERSION="${DRUPAL_VERSION:-11.0}"

# =============================================================================
# STATE MANAGEMENT
# =============================================================================
init_state() {
  [[ -f "$STATE_FILE" ]] || echo '{"envs":{},"db":{},"security":""}' > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

set_state() {
  local tmp
  tmp=$(mktemp)
  jq "$1" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

is_installed() { jq -e ".envs.$1 == true" "$STATE_FILE" >/dev/null 2>&1; }
mark_installed() { set_state ".envs.$1=true"; }

get_db_pass() { jq -r ".db.$1.pass // empty" "$STATE_FILE"; }
set_db_pass() { local env="$1" pass="$2"; set_state ".db.$env={\"user\":\"actools_$env\",\"pass\":\"$pass\"}"; }

rand_pass() { openssl rand -base64 18 | tr -dc A-Za-z0-9 | head -c 20; }

# =============================================================================
# SECURITY PROFILES
# =============================================================================
apply_security() {
  info "Applying security profile: $SECURITY_PROFILE"
  case "$SECURITY_PROFILE" in
    baseline)
      run "apt-get install -y ufw unattended-upgrades"
      run "ufw allow OpenSSH"
      run "ufw --force enable"
      run "dpkg-reconfigure -f noninteractive unattended-upgrades"
      ;;
    standard)
      apply_security_baseline
      run "apt-get install -y auditd"
      run "systemctl enable auditd"
      ;;
    hardened)
      apply_security_standard
      run "apt-get install -y aide apparmor apparmor-utils"
      run "aa-enforce /etc/apparmor.d/* || true"
      run "aideinit || true"
      ;;
    *)
      error "Unknown SECURITY_PROFILE=$SECURITY_PROFILE"
      ;;
  esac
  set_state ".security=\"$SECURITY_PROFILE\""
}

apply_security_baseline() { run "ufw allow OpenSSH"; run "ufw --force enable"; }
apply_security_standard() { apply_security_baseline; run "apt-get install -y auditd"; }

# =============================================================================
# SYSTEM SETUP
# =============================================================================
install_base() {
  info "Installing base packages"
  run "apt-get update -qq"
  run "apt-get install -y -qq curl git unzip zip gnupg jq"
}

install_docker() {
  if ! command -v docker &>/dev/null; then
    info "Installing Docker"
    run "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg"
    run "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable\" > /etc/apt/sources.list.d/docker.list"
    run "apt-get update -qq"
    run "apt-get install -y -qq docker-ce docker-compose-plugin"
  fi
}

# =============================================================================
# DOCKER STACK WITH HTTPS AUTO-GENERATION
# =============================================================================
setup_stack() {
  # Ensure Caddyfile exists
  CADDYFILE="$REAL_HOME/Caddyfile"
  if [[ -d "$CADDYFILE" ]]; then rm -rf "$CADDYFILE"; fi
  [[ -f "$CADDYFILE" ]] || cat <<EOF > "$CADDYFILE"
# Auto-generated Caddyfile with self-signed HTTPS
dev.$BASE_DOMAIN {
    root * /var/www/html/dev
    php_fastcgi php:9000
    file_server
    tls self_signed
}
stg.$BASE_DOMAIN {
    root * /var/www/html/stg
    php_fastcgi php:9000
    file_server
    tls self_signed
}
prod.$BASE_DOMAIN {
    root * /var/www/html/prod
    php_fastcgi php:9000
    file_server
    tls self_signed
}
EOF

  # Docker-compose.yml
  cat > "$REAL_HOME/docker-compose.yml" <<EOF
services:
  caddy:
    image: caddy:2.8-alpine
    ports: ["80:80","443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data

  php:
    image: drupal:11-php${PHP_VERSION}-fpm
    volumes:
      - ./docroot:/var/www/html

  db:
    image: mariadb:${MARIADB_VERSION}
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 2s
      retries: 15
    volumes:
      - db_data:/var/lib/mysql

volumes:
  caddy_data:
  db_data:
EOF

  cd "$REAL_HOME"
  docker compose up -d
}

# =============================================================================
# DB READINESS (idempotent, healthcheck-based)
# =============================================================================
wait_db() {
  info "Waiting for DB to be healthy..."
  for i in {1..30}; do
    CONTAINER_ID=$(docker compose ps -q db)
    if [[ -n "$CONTAINER_ID" ]]; then
      STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_ID")
      if [[ "$STATUS" == "healthy" ]]; then
        info "DB is ready"
        return
      fi
    fi
    sleep 2
  done
  error "DB not healthy after timeout"
}

# =============================================================================
# INSTALL ENV
# =============================================================================
install_env() {
  local env="$1"
  local db="actools_$env"

  if is_installed "$env" && [[ "$FORCE" != true ]]; then
    info "$env already installed — skipping"
    return
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
  "

  mark_installed "$env"
  info "$env installed"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  init_state
  install_base
  install_docker

  info "===== PRE-FLIGHT ====="
  info "User: $REAL_USER"
  info "Domain: $BASE_DOMAIN"
  info "Mode: $MODE"
  info "Security: $SECURITY_PROFILE"

  read -p "Proceed? [y/N] " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 0

  apply_security
  [[ "$MODE" == "fresh" ]] && setup_stack

  for env in dev stg prod; do
    install_env "$env"
  done

  info "All done: https://$BASE_DOMAIN"

  cat <<EOF

Extra tip:
You are using self-signed HTTPS certs for dev/stg/prod.
To replace them with real Let’s Encrypt certs later:
- Update the Caddyfile to remove 'tls self_signed'
- Ensure ports 80/443 are reachable publicly
- Caddy will automatically issue and renew Let’s Encrypt certs

EOF
}

main "$@"

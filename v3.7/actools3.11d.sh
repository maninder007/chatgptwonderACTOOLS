#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Actools Enterprise Installer v3.11d (Ubuntu 24.04)
# =============================================================================

ACTOOLS_VERSION="3.11d"
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
# Logging
# =============================================================================
log() { echo "[$1] $(date '+%F %T') ${*:2}" | tee -a "$LOG_FILE"; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; exit 1; }

run() { [[ "$DRY_RUN" == true ]] && echo "[DRY-RUN] $*" || eval "$@"; }

info "Actools v$ACTOOLS_VERSION started (mode=$MODE)"

# =============================================================================
# Security & Environment Checks
# =============================================================================
[[ "$(id -u)" -eq 0 ]] || error "Run with sudo"
[[ -n "${SUDO_USER:-}" ]] || error "Do NOT run as root directly"
[[ -s "$REAL_HOME/.ssh/authorized_keys" ]] || error "No SSH keys found for $REAL_USER"
[[ -f "$ENV_FILE" ]] || error "Missing $ENV_FILE"
source "$ENV_FILE"

: "${BASE_DOMAIN:?Missing BASE_DOMAIN}"
: "${DRUPAL_ADMIN_EMAIL:?Missing DRUPAL_ADMIN_EMAIL}"
: "${DB_ROOT_PASS:?Missing DB_ROOT_PASS}"

SECURITY_PROFILE="${SECURITY_PROFILE:-baseline}"
PHP_VERSION="${PHP_VERSION:-8.2}"
MARIADB_VERSION="${MARIADB_VERSION:-11.0}"
DRUPAL_VERSION="${DRUPAL_VERSION:-11.0}"

# Lock
[[ -f "$LOCK_FILE" ]] && error "Another run in progress"
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# OS check
lsb_release -cs | grep -q noble || error "Ubuntu 24.04 required"

# =============================================================================
# State Management
# =============================================================================
init_state() { [[ -f "$STATE_FILE" ]] || echo '{"envs":{},"db":{},"security":""}' > "$STATE_FILE"; chmod 600 "$STATE_FILE"; }
set_state() { tmp=$(mktemp); jq "$1" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"; }
is_installed() { jq -e ".envs.$1 == true" "$STATE_FILE" >/dev/null 2>&1; }
mark_installed() { set_state ".envs.$1=true"; }
get_db_pass() { jq -r ".db.$1.pass // empty" "$STATE_FILE"; }
set_db_pass() { local env="$1" pass="$2"; set_state ".db.$env={\"user\":\"actools_$env\",\"pass\":\"$pass\"}"; }
rand_pass() { openssl rand -base64 18 | tr -dc A-Za-z0-9 | head -c 20; }

# =============================================================================
# Security Profiles
# =============================================================================
apply_security() {
    info "Applying security profile: $SECURITY_PROFILE"
    case "$SECURITY_PROFILE" in
        baseline)
            run "apt-get install -y ufw unattended-upgrades netcat-openbsd"
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
# System Setup
# =============================================================================
install_base() {
    info "Installing base packages"
    run "apt-get update -qq"
    run "apt-get install -y -qq curl git unzip zip gnupg jq netcat-openbsd"
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
# Docker Stack with HTTPS auto-generation
# =============================================================================
setup_stack() {
    CADDYFILE="$REAL_HOME/Caddyfile"
    [[ -f "$CADDYFILE" ]] || cat <<EOF > "$CADDYFILE"
# Auto-generated Caddyfile for Actools
# HTTPS self-signed certs for dev/stg/prod
{
    auto_https disable_redirects
}
dev.$BASE_DOMAIN {
    root * /var/www/html/dev
    php_fastcgi php:9000
    file_server
}
stg.$BASE_DOMAIN {
    root * /var/www/html/stg
    php_fastcgi php:9000
    file_server
}
prod.$BASE_DOMAIN {
    root * /var/www/html/prod
    php_fastcgi php:9000
    file_server
}
EOF

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
      test: ["CMD", "nc", "-z", "127.0.0.1", "3306"]
      interval: 2s
      retries: 30
      start_period: 2s
    volumes:
      - db_data:/var/lib/mysql

volumes:
  caddy_data:
  db_data:
EOF

    cd "$REAL_HOME"
    docker compose up -d
}

wait_db() {
    info "Waiting for DB to be healthy..."
    local i=0
    while [[ $i -lt 60 ]]; do
        if docker inspect --format='{{.State.Health.Status}}' varsix-db-1 2>/dev/null | grep -q healthy; then
            info "DB is healthy"
            return
        fi
        sleep 2
        ((i++))
    done
    error "DB not healthy after timeout"
}

# =============================================================================
# Install Environment
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
# Main
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

    cat <<TIP

Extra tip:
- The Caddyfile currently uses self-signed HTTPS for dev/stg/prod.
- To replace with real Let's Encrypt certs for production later:
    1. Remove auto-generated Caddyfile.
    2. Create a new Caddyfile with your domain.
    3. Use: caddy start --config /path/to/Caddyfile
TIP
}

main "$@"

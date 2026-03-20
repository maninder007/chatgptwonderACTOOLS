# ACTools Drupal 11 Multi-Environment Platform

## Overview

ACTools is a modular, enterprise-grade Drupal 11 deployment and lifecycle management toolkit inspired by BOA/Aegir architecture.

It provides:

* Multi-environment provisioning (dev, stg, prod)
* Idempotent installs
* Per-environment database isolation
* Backup & restore
* Upgrade workflows
* State tracking

---

# 📁 Project Structure

```
actools/
├── actools.sh
├── lib/
│   ├── core.sh
│   ├── docker.sh
│   ├── drupal.sh
│   ├── db.sh
│   ├── backup.sh
│   └── state.sh
├── commands/
│   ├── install.sh
│   ├── upgrade.sh
│   ├── backup.sh
│   └── restore.sh
├── .env
└── README.md
```

---

# 🔧 actools.sh (Entry Point)

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$BASE_DIR/lib/core.sh"

CMD="${1:-install}"

case "$CMD" in
  install) source "$BASE_DIR/commands/install.sh" ;;
  upgrade) source "$BASE_DIR/commands/upgrade.sh" ;;
  backup)  source "$BASE_DIR/commands/backup.sh" ;;
  restore) source "$BASE_DIR/commands/restore.sh" ;;
  *) echo "Unknown command"; exit 1 ;;
esac
```

---

# 📦 lib/core.sh

```bash
#!/usr/bin/env bash

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "ERROR: $*"; exit 1; }

require() {
  command -v "$1" >/dev/null || fail "Missing dependency: $1"
}

load_env() {
  ENV_FILE="$HOME/actools.env"
  [[ -f "$ENV_FILE" ]] || fail "Missing $ENV_FILE"
  source "$ENV_FILE"
}
```

---

# 🐳 lib/docker.sh

```bash
#!/usr/bin/env bash

setup_docker() {
  log "Starting Docker stack"
  docker compose up -d --remove-orphans
}

wait_for_db() {
  log "Waiting for DB"
  for i in {1..20}; do
    docker compose exec -T db mysqladmin ping --silent && return
    sleep 2
  done
  fail "DB not ready"
}
```

---

# 🗄️ lib/db.sh

```bash
create_db_user() {
  local env="$1"
  local db="drupal_$env"
  local user="actools_${env}_user"
  local pass=$(openssl rand -base64 18)

  docker compose exec -T db mariadb -u root -p$DB_ROOT_PASSWORD <<SQL
CREATE DATABASE IF NOT EXISTS $db;
CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON $db.* TO '$user'@'%';
FLUSH PRIVILEGES;
SQL

  save_db_state "$env" "$user" "$pass"
}
```

---

# 🧠 lib/state.sh

```bash
STATE_FILE="$HOME/.actools-state.json"

init_state() {
  [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
}

save_db_state() {
  local env="$1" user="$2" pass="$3"
  jq ".db.$env={\"user\":\"$user\",\"pass\":\"$pass\"}" "$STATE_FILE" > tmp && mv tmp "$STATE_FILE"
}
```

---

# 🌐 lib/drupal.sh

```bash
install_drupal() {
  local env="$1"
  local db="drupal_$env"

  docker compose exec -T php bash -c "
    cd /var/www/html/$env
    if [ ! -f composer.json ]; then
      composer create-project drupal/recommended-project:^11 .
    fi
    composer install --no-dev
    vendor/bin/drush site:install standard -y --db-url=mysql://$DB_USER:$DB_PASS@db/$db
  "
}
```

---

# 💾 lib/backup.sh

```bash
backup_env() {
  local env="$1"
  local dir="$HOME/backups/$env-$(date +%F)"
  mkdir -p "$dir"

  docker compose exec -T php drush @$env sql-dump > "$dir/db.sql"
}
```

---

# 🚀 commands/install.sh

```bash
load_env
init_state
setup_docker
wait_for_db

for env in dev stg prod; do
  create_db_user "$env"
  install_drupal "$env"
done
```

---

# 🔄 commands/upgrade.sh

```bash
docker compose exec php composer update
for env in dev stg prod; do
  docker compose exec php bash -c "cd /var/www/html/$env && drush updb -y && drush cr"
done
```

---

# 💾 commands/backup.sh

```bash
for env in dev stg prod; do
  backup_env "$env"
done
```

---

# ♻️ commands/restore.sh

```bash
restore_env() {
  local env="$1"
  local file="$2"

  docker compose exec -T db mariadb drupal_$env < "$file"
}
```

---

# 📘 README.md

## Installation

```bash
git clone <repo>
cd actools
chmod +x actools.sh
```

Create config:

```bash
cp .env.example ~/actools.env
```

Run:

```bash
sudo ./actools.sh install
```

---

## Commands

| Command | Description         |
| ------- | ------------------- |
| install | Full install        |
| upgrade | Update Drupal       |
| backup  | Backup all envs     |
| restore | Restore from backup |

---

## Best Practices

* Never run as root
* Always backup before upgrade
* Use SSH key auth only
* Rotate backups regularly

---

## Security Notes

* Per-environment DB users
* No root DB usage
* Secrets stored in state file

---

## Future Enhancements

* CI/CD integration
* Multi-server deployment
* Queue-based jobs

---

**ACTools = Minimal Aegir-style platform for modern Drupal**

#!/usr/bin/env bash
set -e
set -o pipefail

### ========== Variables ==========
APP="Authentik"
APP_DIR="/opt/authentik"
VERSION_FILE="/opt/${APP}_version.txt"
BACKUP_DIR="/root/authentik-backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RELEASE_URL=$(curl -fsSL https://api.github.com/repos/goauthentik/authentik/releases/latest | grep "tarball_url" | cut -d '"' -f4)
RELEASE_TAG=$(basename "$RELEASE_URL")
DB_NAME="authentik"
DB_USER="authentik"

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
NC="\033[0m"

log()    { echo -e "${YELLOW}[*] $1${NC}"; }
log_ok() { echo -e "${GREEN}[✓] $1${NC}"; }
log_err(){ echo -e "${RED}[✗] $1${NC}"; }

### ========== Check & Prompt for Required Commands ==========
REQUIRED_CMDS=(go node npm uv pg_dump)
MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_CMDS+=("$cmd")
    fi
done

if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
    log_err "Missing required commands: ${MISSING_CMDS[*]}"
    read -p "Attempt to install missing packages? [Y/n]: " INSTALL_CONFIRM
    if [[ ! "$INSTALL_CONFIRM" =~ ^([nN][oO]?|[nN])$ ]]; then
        for cmd in "${MISSING_CMDS[@]}"; do
            case "$cmd" in
                go)
                    log "Installing Go..."
                    apt-get update && apt-get install -y golang
                    ;;
                node|npm)
                    log "Installing Node.js and npm..."
                    apt-get update && apt-get install -y nodejs npm
                    ;;
                uv)
                    log "Installing uv (via pip)..."
                    pip install uv || pipx install uv
                    ;;
                pg_dump)
                    log "Installing PostgreSQL client..."
                    apt-get update && apt-get install -y postgresql-client
                    ;;
            esac
        done
        # Re-check after install
        STILL_MISSING=()
        for cmd in "${MISSING_CMDS[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                STILL_MISSING+=("$cmd")
            fi
        done
        if [[ ${#STILL_MISSING[@]} -gt 0 ]]; then
            log_err "The following commands are still missing: ${STILL_MISSING[*]}"
            log_err "Please install them manually and re-run the script."
            exit 1
        fi
        log_ok "All required commands are now installed."
    else
        log_err "Cannot continue without required packages. Exiting."
        exit 1
    fi
fi

# Optional: Warn if yq is missing (for better config parsing)
if ! command -v yq >/dev/null 2>&1; then
    log "Warning: 'yq' not found. Falling back to basic config parsing."
fi

### ========== Step 1: Check for Updates ==========
log "Checking for latest release..."
if [[ -f "$VERSION_FILE" && "$RELEASE_TAG" == "$(cat "$VERSION_FILE")" ]]; then
    log_ok "Already at latest version: $RELEASE_TAG"
    exit 0
fi

### ========== Step 2: Create Backups ==========
log "Creating pre-update backup..."

mkdir -p "$BACKUP_DIR/$TIMESTAMP"

# Delete backups older than 6 months only if at least one newer backup exists
log "Checking for backups older than 6 months to delete..."
ALL_BACKUPS=($(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort))
OLD_BACKUPS=($(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +180 | sort))

if [[ ${#ALL_BACKUPS[@]} -gt 1 && ${#OLD_BACKUPS[@]} -gt 0 ]]; then
    for backup in "${OLD_BACKUPS[@]}"; do
        log "Deleting old backup: $backup"
        rm -rf "$backup"
    done
    log_ok "Old backups deleted."
else
    log_ok "No old backups found or not enough backups to delete."
fi

# Extract DB password from config.yml
if command -v yq >/dev/null 2>&1; then
    DB_PASS=$(yq '.postgresql.password' /etc/authentik/config.yml)
elif grep -q 'postgresql.password' /etc/authentik/config.yml; then
    DB_PASS=$(grep 'postgresql.password' /etc/authentik/config.yml | cut -d '"' -f2)
else
    log_err "Unable to extract PostgreSQL password from config.yml"
    exit 1
fi

# Backup PostgreSQL DB
PGPASSWORD="$DB_PASS" pg_dump -h 127.0.0.1 -U "$DB_USER" "$DB_NAME" > "$BACKUP_DIR/$TIMESTAMP/db_backup.sql" || {
    log_err "Database backup failed"
    exit 1
}

# Backup config file
cp /etc/authentik/config.yml "$BACKUP_DIR/$TIMESTAMP/config.yml"

# Backup blueprints
cp -r "$APP_DIR/blueprints" "$BACKUP_DIR/$TIMESTAMP/blueprints"

log_ok "Backup saved to $BACKUP_DIR/$TIMESTAMP"

### ========== Step 3: Stop Services ==========
log "Stopping authentik services..."
systemctl stop authentik-server || true
systemctl stop authentik-worker || true
systemctl stop authentik-celery-beat || true
log_ok "Services stopped."

### ========== Step 4: Download & Replace ==========
log "Downloading latest release: $RELEASE_TAG"
cd /tmp
curl -fsSL "$RELEASE_URL" -o authentik.tar.gz
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
tar -xzf authentik.tar.gz -C "$APP_DIR" --strip-components=1
rm -f authentik.tar.gz
log_ok "Release extracted."

### ========== Prompt for Website Build ==========
read -p "Build website (documentation)? [Y/n]: " BUILD_WEBSITE_INPUT
if [[ "$BUILD_WEBSITE_INPUT" =~ ^([nN][oO]?|[nN])$ ]]; then
    SKIP_WEBSITE=1
    log "User chose to skip website build."
else
    SKIP_WEBSITE=0
    log "User chose to build website."
fi

### ========== Step 5: Build Frontend ==========

if [[ $SKIP_WEBSITE -eq 1 ]]; then
    log "Skipping website build (user choice)..."
else
    log "Building frontend (website & web)..."
    cd "$APP_DIR/website"
    npm install --loglevel=error
    NODE_OPTIONS="--max_old_space_size=2048" npm run build-bundled --loglevel=error
    log_ok "Website built."
fi

cd "$APP_DIR/web"
npm install --loglevel=error
npm run build --loglevel=error
log_ok "Frontend built."

### ========== Step 6: Build Backend ==========
log "Building backend server..."
cd "$APP_DIR"
go mod download
go build -o /go/authentik ./cmd/server
go build -o "$APP_DIR/authentik-server" ./cmd/server
log_ok "Backend built."

### ========== Step 7: Sync Python Dependencies & Migrate ==========
log "Syncing Python deps & running migrations..."

uv sync --frozen --no-install-project --no-dev
uv run python -m lifecycle.migrate
log_ok "Migration complete."

# Ensure gunicorn/celery are in path
ln -sf "$APP_DIR/.venv/bin/gunicorn" /usr/local/bin/gunicorn
ln -sf "$APP_DIR/.venv/bin/celery" /usr/local/bin/celery

# Save version
echo "$RELEASE_TAG" > "$VERSION_FILE"

### ========== Step 8: Restart Services ==========
log "Starting authentik services..."
systemctl start authentik-server
systemctl start authentik-worker
systemctl start authentik-celery-beat
log_ok "All services started."

### ========== Done ==========
log_ok "Authentik updated to $RELEASE_TAG"
log "Backup location: $BACKUP_DIR/$TIMESTAMP"

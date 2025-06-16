#!/usr/bin/env bash
set -e

APP="Authentik"
APP_DIR="/opt/authentik"
VERSION_FILE="/opt/${APP}_version.txt"

echo "[*] Checking for latest release..."
RELEASE_URL=$(curl -fsSL https://api.github.com/repos/goauthentik/authentik/releases/latest | grep "tarball_url" | cut -d '"' -f4)
RELEASE_TAG=$(basename "$RELEASE_URL")

if [[ -f "$VERSION_FILE" && "$RELEASE_TAG" == "$(cat "$VERSION_FILE")" ]]; then
    echo "[✓] Already at latest version: $RELEASE_TAG"
    exit 0
fi

echo "[*] Stopping services..."
systemctl stop authentik-server authentik-worker || true

echo "[*] Downloading release: $RELEASE_TAG"
cd /tmp
curl -fsSL "$RELEASE_URL" -o authentik.tar.gz
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
tar -xzf authentik.tar.gz -C "$APP_DIR" --strip-components=1
rm -f authentik.tar.gz

echo "[*] Building frontend..."
cd "$APP_DIR/website"
npm install
npm run build-bundled

cd "$APP_DIR/web"
npm install
npm run build

echo "[*] Building backend..."
cd "$APP_DIR"
go mod download
go build -o /go/authentik ./cmd/server
go build -o "$APP_DIR/authentik-server" ./cmd/server

echo "[*] Syncing Python deps and running migrations..."
uv sync --frozen --no-install-project --no-dev
uv run python -m lifecycle.migrate

ln -sf "$APP_DIR/.venv/bin/gunicorn" /usr/local/bin/gunicorn
ln -sf "$APP_DIR/.venv/bin/celery" /usr/local/bin/celery

echo "$RELEASE_TAG" > "$VERSION_FILE"

echo "[*] Starting services..."
systemctl start authentik-server
systemctl start authentik-worker

echo "[✓] Authentik updated to $RELEASE_TAG"

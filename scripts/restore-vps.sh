#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# VPS FULL RESTORE
# Restores the Content Factory / n8n / Render / TTS stack
# from a backup created by backup-vps.sh.
#
# IMPORTANT:
# - Run on a fresh/rebuilt VPS as root.
# - The backup directory must be available locally.
# - This script intentionally does NOT overwrite /etc/ssh automatically.
# - Docker must be installed before running this script.
# ============================================================

BACKUP_DIR=""
ASSUME_YES=0
SKIP_SYSTEM_CONFIG=0

usage() {
    cat <<'EOF'
Usage:
  sudo ./restore-vps.sh --backup-dir /path/to/backup
  sudo ./restore-vps.sh --backup-dir /path/to/backup --yes

Options:
  --backup-dir PATH   Backup directory created by backup-vps.sh (required)
  --yes               Skip confirmation prompts
  --skip-system       Do not restore UFW/Fail2Ban/Docker/systemd config archives
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup-dir)
            BACKUP_DIR="${2:-}"
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --skip-system)
            SKIP_SYSTEM_CONFIG=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run this script with sudo/root."
    exit 1
fi

if [[ -z "$BACKUP_DIR" ]]; then
    echo "ERROR: --backup-dir is required."
    usage
    exit 1
fi

BACKUP_DIR="$(realpath "$BACKUP_DIR")"
CHECKSUM_FILE="$BACKUP_DIR/manifest/checksums.sha256"

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "ERROR: backup directory not found: $BACKUP_DIR"
    exit 1
fi

if [[ ! -f "$CHECKSUM_FILE" ]]; then
    echo "ERROR: checksum file not found: $CHECKSUM_FILE"
    exit 1
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

confirm() {
    local question="$1"
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        return 0
    fi

    echo
    read -r -p "$question [yes/NO]: " answer
    [[ "$answer" == "yes" ]]
}

require_file() {
    local f="$1"
    [[ -f "$f" ]] || {
        echo "ERROR: required file missing: $f"
        exit 1
    }
}

require_dir() {
    local d="$1"
    [[ -d "$d" ]] || {
        echo "ERROR: required directory missing: $d"
        exit 1
    }
}

restore_tar() {
    local archive="$1"
    local destination="$2"
    require_file "$archive"
    mkdir -p "$destination"
    tar -xzf "$archive" -C "$destination"
}

compose_up() {
    local compose="$1"
    if [[ -f "$compose" ]]; then
        echo "  docker compose up: $compose"
        docker compose -f "$compose" up -d
    else
        echo "  WARNING: compose not found: $compose"
    fi
}

wait_for_postgres() {
    echo "  Waiting for PostgreSQL..."
    for i in {1..60}; do
        if docker exec postgres pg_isready -U admin -d postgres >/dev/null 2>&1; then
            echo "  PostgreSQL is ready."
            return 0
        fi
        sleep 2
    done
    echo "ERROR: PostgreSQL did not become ready."
    exit 1
}

# ------------------------------------------------------------
# Safety information
# ------------------------------------------------------------

echo "============================================================"
echo " VPS FULL RESTORE"
echo "============================================================"
echo "Backup : $BACKUP_DIR"
echo

if [[ -f "$BACKUP_DIR/manifest/README.txt" ]]; then
    cat "$BACKUP_DIR/manifest/README.txt"
fi

echo
echo "WARNING: this operation restores system/application data."
echo "It is intended for a rebuilt/fresh VPS."
echo

if ! confirm "Continue with RESTORE?"; then
    echo "Restore cancelled."
    exit 0
fi

# ------------------------------------------------------------
# 1. Verify backup integrity
# ------------------------------------------------------------

echo
 echo "[1/12] Verifying backup checksum..."
(
    cd "$BACKUP_DIR"
    sha256sum -c manifest/checksums.sha256
)

echo "Checksum verification: OK"

# ------------------------------------------------------------
# 2. Basic packages / directories
# ------------------------------------------------------------

echo
 echo "[2/12] Preparing filesystem..."

mkdir -p /opt/stacks
mkdir -p /opt/npm
mkdir -p /opt/dockge
mkdir -p /opt/content-factory/docker
mkdir -p /opt/backup
mkdir -p /opt/scripts

# ------------------------------------------------------------
# 3. Restore Compose/configuration files
# ------------------------------------------------------------

echo
 echo "[3/12] Restoring Docker Compose/configuration..."

if [[ -d "$BACKUP_DIR/docker/compose/stacks" ]]; then
    cp -a "$BACKUP_DIR/docker/compose/stacks/." /opt/stacks/
fi

if [[ -d "$BACKUP_DIR/docker/compose/npm" ]]; then
    cp -a "$BACKUP_DIR/docker/compose/npm/." /opt/npm/
fi

if [[ -d "$BACKUP_DIR/docker/compose/dockge" ]]; then
    cp -a "$BACKUP_DIR/docker/compose/dockge/." /opt/dockge/
fi

if [[ -d "$BACKUP_DIR/docker/compose/content-factory-docker" ]]; then
    cp -a "$BACKUP_DIR/docker/compose/content-factory-docker/." /opt/content-factory/docker/
fi

# ------------------------------------------------------------
# 4. Restore Docker application data
# ------------------------------------------------------------

echo
 echo "[4/12] Restoring Docker application data..."

restore_tar "$BACKUP_DIR/docker/data/n8n-data.tar.gz" /opt/stacks/n8n
restore_tar "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz" /opt/stacks/cloudbeaver
restore_tar "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz" /opt/stacks/uptime-kuma
restore_tar "$BACKUP_DIR/docker/data/npm-data.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/dockge-data.tar.gz" /opt/dockge

# ------------------------------------------------------------
# 5. Restore Docker named volumes
# ------------------------------------------------------------

echo
 echo "[5/12] Restoring Docker named volumes..."

# Docker volumes must exist before data is imported.
docker volume create portainer_portainer_data >/dev/null

docker run --rm \
    -v portainer_portainer_data:/target \
    -v "$BACKUP_DIR/docker/volumes":/backup:ro \
    alpine sh -c 'tar xzf /backup/portainer_portainer_data.tar.gz -C /target'

if [[ -f "$BACKUP_DIR/docker/volumes/n8n-sandbox_sandbox-tls.tar.gz" ]]; then
    docker volume create n8n-sandbox_sandbox-tls >/dev/null
    docker run --rm \
        -v n8n-sandbox_sandbox-tls:/target \
        -v "$BACKUP_DIR/docker/volumes":/backup:ro \
        alpine sh -c 'tar xzf /backup/n8n-sandbox_sandbox-tls.tar.gz -C /target'
fi

# ------------------------------------------------------------
# 6. Create Docker network
# ------------------------------------------------------------

echo
 echo "[6/12] Preparing Docker network..."

if ! docker network inspect proxy >/dev/null 2>&1; then
    docker network create proxy
fi

# ------------------------------------------------------------
# 7. Start PostgreSQL only
# ------------------------------------------------------------

echo
 echo "[7/12] Starting PostgreSQL..."

require_file /opt/stacks/postgres/compose.yaml

docker compose -f /opt/stacks/postgres/compose.yaml up -d postgres
wait_for_postgres

# ------------------------------------------------------------
# 8. Restore PostgreSQL roles + databases
# ------------------------------------------------------------

echo
 echo "[8/12] Restoring PostgreSQL..."

require_file "$BACKUP_DIR/postgres/globals.sql"
require_file "$BACKUP_DIR/postgres/n8n_konten.dump"
require_file "$BACKUP_DIR/postgres/postgres.dump"

# Restore roles first. Ignore errors for roles that already exist.
docker exec -i postgres psql -U admin -d postgres \
    < "$BACKUP_DIR/postgres/globals.sql" \
    || true

# Ensure n8n_konten exists.
if ! docker exec postgres psql -U admin -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='n8n_konten'" | grep -q 1; then
    docker exec postgres psql -U admin -d postgres \
        -c 'CREATE DATABASE n8n_konten OWNER n8n;'
fi

# Restore the n8n database.
docker cp "$BACKUP_DIR/postgres/n8n_konten.dump" postgres:/tmp/n8n_konten.dump

docker exec postgres pg_restore \
    -U admin \
    -d n8n_konten \
    --clean \
    --if-exists \
    --no-owner \
    /tmp/n8n_konten.dump

docker exec postgres rm -f /tmp/n8n_konten.dump

# Restore the postgres database contents.
docker cp "$BACKUP_DIR/postgres/postgres.dump" postgres:/tmp/postgres.dump

docker exec postgres pg_restore \
    -U admin \
    -d postgres \
    --clean \
    --if-exists \
    --no-owner \
    /tmp/postgres.dump \
    || true

docker exec postgres rm -f /tmp/postgres.dump

# ------------------------------------------------------------
# 9. Start application stacks
# ------------------------------------------------------------

echo
 echo "[9/12] Starting Docker application stacks..."

# NPM first because it provides reverse proxy/SSL.
compose_up /opt/npm/compose.yaml

# n8n sandbox before n8n.
compose_up /opt/stacks/n8n-sandbox/compose.yaml

# n8n itself.
compose_up /opt/stacks/n8n/compose.yaml

# Remaining applications.
compose_up /opt/stacks/cloudbeaver/compose.yaml
compose_up /opt/stacks/uptime-kuma/compose.yaml
compose_up /opt/dockge/compose.yaml

# Portainer compose lives in the content-factory tree.
if [[ -f /opt/content-factory/docker/portainer/docker-compose.yml ]]; then
    compose_up /opt/content-factory/docker/portainer/docker-compose.yml
fi

# ------------------------------------------------------------
# 10. Restore Render + TTS services
# ------------------------------------------------------------

echo
 echo "[10/12] Restoring Render/TTS services..."

if [[ -f "$BACKUP_DIR/services/render-service/render-service.tar.gz" ]]; then
    rm -rf /opt/render-service
    mkdir -p /opt
    tar -xzf "$BACKUP_DIR/services/render-service/render-service.tar.gz" -C /opt
fi

if [[ -f "$BACKUP_DIR/services/tts-service/tts-service.tar.gz" ]]; then
    rm -rf /opt/tts-service
    mkdir -p /opt
    tar -xzf "$BACKUP_DIR/services/tts-service/tts-service.tar.gz" -C /opt
fi

if [[ -f "$BACKUP_DIR/services/render-service/render-service.service" ]]; then
    cp "$BACKUP_DIR/services/render-service/render-service.service" \
        /etc/systemd/system/render-service.service
fi

if [[ -f "$BACKUP_DIR/services/tts-service/tts-service.service" ]]; then
    cp "$BACKUP_DIR/services/tts-service/tts-service.service" \
        /etc/systemd/system/tts-service.service
fi

# Reinstall Python dependencies if pip exists.
if [[ -x /opt/render-service/venv/bin/pip && -f "$BACKUP_DIR/services/render-service/requirements.freeze.txt" ]]; then
    /opt/render-service/venv/bin/pip install -r \
        "$BACKUP_DIR/services/render-service/requirements.freeze.txt" || true
fi

if [[ -x /opt/tts-service/venv/bin/pip && -f "$BACKUP_DIR/services/tts-service/requirements.freeze.txt" ]]; then
    /opt/tts-service/venv/bin/pip install -r \
        "$BACKUP_DIR/services/tts-service/requirements.freeze.txt" || true
fi

# Correct ownership for application services.
if id zkonten >/dev/null 2>&1; then
    chown -R zkonten:zkonten /opt/render-service /opt/tts-service 2>/dev/null || true
fi

systemctl daemon-reload
systemctl enable render-service.service tts-service.service
systemctl restart render-service.service
auto_restart_tts=1
systemctl restart tts-service.service

# ------------------------------------------------------------
# 11. Optional system configuration
# ------------------------------------------------------------

echo
 echo "[11/12] Restoring system configuration..."

if [[ "$SKIP_SYSTEM_CONFIG" -eq 0 ]]; then
    # Docker daemon configuration.
    if [[ -f "$BACKUP_DIR/system/docker-config.tar.gz" ]]; then
        tar -xzf "$BACKUP_DIR/system/docker-config.tar.gz" -C /etc
    fi

    # Firewall configuration is restored only if UFW exists.
    if [[ -f "$BACKUP_DIR/system/ufw.tar.gz" && -d /etc/ufw ]]; then
        tar -xzf "$BACKUP_DIR/system/ufw.tar.gz" -C /etc
    fi

    # Fail2Ban configuration.
    if [[ -f "$BACKUP_DIR/system/fail2ban.tar.gz" ]]; then
        tar -xzf "$BACKUP_DIR/system/fail2ban.tar.gz" -C /etc
    fi

    # Cron configuration.
    if [[ -f "$BACKUP_DIR/system/cron.tar.gz" ]]; then
        tar -xzf "$BACKUP_DIR/system/cron.tar.gz" -C /etc
    fi

    systemctl daemon-reload

    # IMPORTANT: SSH is intentionally NOT restored automatically.
    # A changed sshd_config can lock the administrator out of a new VPS.
    echo "  SSH configuration NOT restored automatically (safety)."
else
    echo "  System config restore skipped by --skip-system."
fi

# ------------------------------------------------------------
# 12. Final health check
# ------------------------------------------------------------

echo
 echo "[12/12] Final health check..."

sleep 5

echo
echo "===== DOCKER CONTAINERS ====="
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo

echo "===== DOCKER NETWORK ====="
docker network inspect proxy --format '{{range .Containers}}{{println .Name}}{{end}}' 2>/dev/null || true

echo

echo "===== SERVICES ====="
systemctl --no-pager --full status render-service.service --lines=5 || true
systemctl --no-pager --full status tts-service.service --lines=5 || true

echo

echo "===== POSTGRES DATABASES ====="
docker exec postgres psql -U admin -d postgres -c '\l' || true

echo

echo "===== n8n HEALTH ====="
if curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    echo "n8n health: OK"
else
    echo "n8n health: endpoint not responding on 127.0.0.1:5678"
fi

echo
 echo "============================================================"
echo " RESTORE SELESAI"
echo "============================================================"
echo
 echo "Backup source: $BACKUP_DIR"
echo
 echo "IMPORTANT:"
echo "1. Verify n8n login/workflows."
echo "2. Verify NPM Proxy Hosts + SSL."
echo "3. Verify Render Service /health on port 5006."
echo "4. Verify TTS Service on its configured port."
echo "5. Verify UFW/SSH manually before closing the current SSH session."
echo
SCRIPT
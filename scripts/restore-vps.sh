#!/usr/bin/env bash
set -Eeuo pipefail

# VPS Recovery Kit - Restore v6
# Safe by default: --dry-run changes nothing.
# System configuration and SSH are NOT restored automatically.

BACKUP_DIR=""
DRY_RUN=0
YES=0
RESTORE_SYSTEM=0

usage() {
cat <<'USAGE'
Usage:
  sudo ./restore-vps.sh --backup-dir /path/to/backup --dry-run
  sudo ./restore-vps.sh --backup-dir /path/to/backup

Options:
  --backup-dir PATH   Recovery backup directory (required)
  --dry-run           Validate backup and host only; change nothing
  --yes               Skip restore confirmation
  --restore-system    Restore Docker/UFW/Fail2Ban/cron/systemd config

Notes:
  SSH configuration is never restored automatically.
  System configuration is skipped unless --restore-system is supplied.
USAGE
}

error() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || error "Required command missing: $1"; }
need_file() { [[ -f "$1" ]] || error "Required backup file missing: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir) [[ $# -ge 2 ]] || error "--backup-dir requires a path"; BACKUP_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    --restore-system) RESTORE_SYSTEM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || error "Run this script with sudo/root."
[[ -n "$BACKUP_DIR" ]] || error "--backup-dir is required."

for c in realpath tar sha256sum docker systemctl curl; do need_cmd "$c"; done
BACKUP_DIR="$(realpath "$BACKUP_DIR")"
[[ -d "$BACKUP_DIR" ]] || error "Backup directory does not exist: $BACKUP_DIR"
CHECKSUMS="$BACKUP_DIR/manifest/checksums.sha256"
need_file "$CHECKSUMS"

REQUIRED_FILES=(
  "$BACKUP_DIR/docker/compose/stacks/n8n/compose.yaml"
  "$BACKUP_DIR/docker/compose/stacks/n8n/.env"
  "$BACKUP_DIR/docker/compose/stacks/n8n-sandbox/compose.yaml"
  "$BACKUP_DIR/docker/compose/stacks/n8n-sandbox/.env"
  "$BACKUP_DIR/docker/compose/stacks/postgres/compose.yaml"
  "$BACKUP_DIR/docker/compose/stacks/postgres/.env"
  "$BACKUP_DIR/docker/compose/stacks/cloudbeaver/compose.yaml"
  "$BACKUP_DIR/docker/compose/stacks/uptime-kuma/compose.yaml"
  "$BACKUP_DIR/docker/compose/npm/compose.yaml"
  "$BACKUP_DIR/docker/compose/dockge/compose.yaml"
  "$BACKUP_DIR/docker/compose/content-factory-docker/portainer/docker-compose.yml"
  "$BACKUP_DIR/docker/data/n8n-data.tar.gz"
  "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz"
  "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz"
  "$BACKUP_DIR/docker/data/npm-data.tar.gz"
  "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz"
  "$BACKUP_DIR/docker/data/dockge-data.tar.gz"
  "$BACKUP_DIR/docker/volumes/portainer_portainer_data.tar.gz"
  "$BACKUP_DIR/docker/volumes/n8n-sandbox_sandbox-tls.tar.gz"
  "$BACKUP_DIR/postgres/n8n_konten.dump"
  "$BACKUP_DIR/postgres/postgres.dump"
  "$BACKUP_DIR/postgres/globals.sql"
  "$BACKUP_DIR/services/render-service/render-service.tar.gz"
  "$BACKUP_DIR/services/render-service/render-service.service"
  "$BACKUP_DIR/services/render-service/requirements.freeze.txt"
  "$BACKUP_DIR/services/tts-service/tts-service.tar.gz"
  "$BACKUP_DIR/services/tts-service/tts-service.service"
  "$BACKUP_DIR/services/tts-service/requirements.freeze.txt"
)

ARCHIVES=(
  "$BACKUP_DIR/docker/data/n8n-data.tar.gz"
  "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz"
  "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz"
  "$BACKUP_DIR/docker/data/npm-data.tar.gz"
  "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz"
  "$BACKUP_DIR/docker/data/dockge-data.tar.gz"
  "$BACKUP_DIR/docker/volumes/portainer_portainer_data.tar.gz"
  "$BACKUP_DIR/docker/volumes/n8n-sandbox_sandbox-tls.tar.gz"
  "$BACKUP_DIR/services/render-service/render-service.tar.gz"
  "$BACKUP_DIR/services/tts-service/tts-service.tar.gz"
)

echo "============================================================"
echo " VPS FULL RESTORE v6"
echo "============================================================"
echo "Backup: $BACKUP_DIR"
echo

echo "Checking backup structure..."
for f in "${REQUIRED_FILES[@]}"; do need_file "$f"; done
echo "Backup structure: OK"

echo
echo "Checking archive readability..."
for a in "${ARCHIVES[@]}"; do
  tar -tzf "$a" >/dev/null
  echo "  OK: $(basename "$a")"
done
echo "Archive readability: OK"

echo
echo "Checking SHA-256..."
(
  cd "$BACKUP_DIR"
  sha256sum -c "$CHECKSUMS"
)
echo
echo "Checksum verification: OK"

echo
echo "Checking Docker image availability..."
if docker info >/dev/null 2>&1 && [[ -f "$BACKUP_DIR/manifest/docker-images.txt" ]]; then
  awk '$1 !~ /^(REPOSITORY|=====|$)/ && $1 !~ /^\// && $3 ~ /^sha256:/ {print $1 ":" $2}' "$BACKUP_DIR/manifest/docker-images.txt" | while read -r image; do
    if docker image inspect "$image" >/dev/null 2>&1; then
      echo "  PRESENT: $image"
    else
      echo "  MISSING: $image"
    fi
  done
else
  echo "  Docker daemon or image manifest unavailable."
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
echo "============================================================"
  echo " DRY-RUN PASSED"
  echo "============================================================"
  echo "No files, containers, databases, services, or firewall rules were changed."
  exit 0
fi

if [[ "$YES" -ne 1 ]]; then
  echo
echo "============================================================"
  echo " WARNING: LIVE RESTORE"
  echo "============================================================"
  echo "This operation will modify this VPS."
  read -r -p "Type YES to continue: " answer
  [[ "$answer" == "YES" ]] || { echo "Restore cancelled."; exit 0; }
fi

STAMP="$(date +%F-%H%M%S)"
SAFETY="/opt/recovery-before-restore/$STAMP"
mkdir -p "$SAFETY"

restore_tar() {
  local archive="$1" destination="$2"
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination"
}

compose_up() {
  docker compose -f "$1" up -d
}

wait_postgres() {
  for i in {1..60}; do
    if docker exec postgres pg_isready -U admin -d postgres >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  error "PostgreSQL did not become ready."
}

echo
echo "[1/10] Creating pre-restore safety snapshot..."
for p in /opt/stacks /opt/npm /opt/dockge /opt/content-factory/docker /opt/render-service /opt/tts-service; do
  if [[ -e "$p" ]]; then
    tar -czf "$SAFETY/$(basename "$p").tar.gz" "$p"
  fi
done
echo "  Safety snapshot: $SAFETY"

echo
echo "[2/10] Preparing Docker network..."
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy >/dev/null

echo
echo "[3/10] Restoring Docker Compose files..."
mkdir -p /opt/stacks /opt/npm /opt/dockge /opt/content-factory/docker
cp -a "$BACKUP_DIR/docker/compose/stacks/." /opt/stacks/
cp -a "$BACKUP_DIR/docker/compose/npm/." /opt/npm/
cp -a "$BACKUP_DIR/docker/compose/dockge/." /opt/dockge/
cp -a "$BACKUP_DIR/docker/compose/content-factory-docker/." /opt/content-factory/docker/

echo
echo "[4/10] Restoring Docker data..."
restore_tar "$BACKUP_DIR/docker/data/n8n-data.tar.gz" /opt/stacks/n8n
restore_tar "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz" /opt/stacks/cloudbeaver
restore_tar "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz" /opt/stacks/uptime-kuma
restore_tar "$BACKUP_DIR/docker/data/npm-data.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/dockge-data.tar.gz" /opt/dockge

echo
echo "[5/10] Restoring Docker volumes..."
docker volume inspect portainer_portainer_data >/dev/null 2>&1 || docker volume create portainer_portainer_data >/dev/null
docker run --rm -v portainer_portainer_data:/target -v "$BACKUP_DIR/docker/volumes":/backup:ro alpine sh -c 'tar xzf /backup/portainer_portainer_data.tar.gz -C /target'
docker volume inspect n8n-sandbox_sandbox-tls >/dev/null 2>&1 || docker volume create n8n-sandbox_sandbox-tls >/dev/null
docker run --rm -v n8n-sandbox_sandbox-tls:/target -v "$BACKUP_DIR/docker/volumes":/backup:ro alpine sh -c 'tar xzf /backup/n8n-sandbox_sandbox-tls.tar.gz -C /target'

echo
echo "[6/10] Restoring PostgreSQL..."
compose_up /opt/stacks/postgres/compose.yaml
wait_postgres
docker exec -i postgres psql -U admin -d postgres < "$BACKUP_DIR/postgres/globals.sql" || true
docker cp "$BACKUP_DIR/postgres/n8n_konten.dump" postgres:/tmp/n8n_konten.dump
docker exec postgres pg_restore -U admin -d n8n_konten --clean --if-exists --no-owner --exit-on-error /tmp/n8n_konten.dump
docker exec postgres rm -f /tmp/n8n_konten.dump

echo
echo "[7/10] Restoring Render and TTS services..."
mkdir -p /opt/render-service /opt/tts-service
restore_tar "$BACKUP_DIR/services/render-service/render-service.tar.gz" /opt
restore_tar "$BACKUP_DIR/services/tts-service/tts-service.tar.gz" /opt
cp "$BACKUP_DIR/services/render-service/render-service.service" /etc/systemd/system/render-service.service
cp "$BACKUP_DIR/services/tts-service/tts-service.service" /etc/systemd/system/tts-service.service
if id zkonten >/dev/null 2>&1; then
  chown -R zkonten:zkonten /opt/render-service /opt/tts-service
fi

echo
echo "[8/10] Restoring optional system configuration..."
if [[ "$RESTORE_SYSTEM" -eq 1 ]]; then
  tar -xzf "$BACKUP_DIR/system/docker-config.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/ufw.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/fail2ban.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/cron.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/systemd.tar.gz" -C /etc
  echo "  System configuration restored."
else
  echo "  Skipped (use --restore-system when intentionally restoring host config)."
fi
echo "  SSH configuration: NEVER restored automatically."

echo
echo "[9/10] Starting services..."
systemctl daemon-reload
compose_up /opt/stacks/postgres/compose.yaml
compose_up /opt/npm/compose.yaml
compose_up /opt/stacks/n8n-sandbox/compose.yaml
compose_up /opt/stacks/n8n/compose.yaml
compose_up /opt/stacks/cloudbeaver/compose.yaml
compose_up /opt/stacks/uptime-kuma/compose.yaml
compose_up /opt/dockge/compose.yaml
compose_up /opt/content-factory/docker/portainer/docker-compose.yml
systemctl enable render-service.service tts-service.service
systemctl restart render-service.service
systemctl restart tts-service.service

echo
echo "[10/10] Running health checks..."
sleep 5
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
echo
if docker exec postgres pg_isready -U admin -d postgres >/dev/null 2>&1; then echo "PostgreSQL: OK"; else echo "PostgreSQL: FAILED"; fi
if curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1; then echo "n8n /healthz: OK"; else echo "n8n /healthz: NOT RESPONDING"; fi
if curl -fsS http://127.0.0.1:5006/health >/dev/null 2>&1; then echo "Render /health: OK"; else echo "Render /health: FAILED"; fi
if systemctl is-active --quiet tts-service.service; then echo "TTS service: OK"; else echo "TTS service: FAILED"; fi

echo
echo "============================================================"
echo " RESTORE FINISHED"
echo "============================================================"
echo "Pre-restore safety snapshot: $SAFETY"
echo "Verify n8n, NPM/SSL, Render, TTS, and SSH before closing the session."
echo
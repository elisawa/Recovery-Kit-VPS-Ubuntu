#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# VPS FULL RESTORE v3
# Restore a backup created by backup-vps.sh.
# Designed for a rebuilt/fresh Ubuntu VPS.
# SSH is NEVER overwritten automatically.
# ============================================================

BACKUP_DIR=""
YES=0
SKIP_SYSTEM=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./restore-vps.sh --backup-dir /path/to/backup --dry-run
  sudo ./restore-vps.sh --backup-dir /path/to/backup
  sudo ./restore-vps.sh --backup-dir /path/to/backup --skip-system
  sudo ./restore-vps.sh --backup-dir /path/to/backup --yes

Options:
  --backup-dir PATH   Recovery backup directory (required)
  --dry-run           Validate backup and host only; change nothing
  --yes               Skip confirmation
  --skip-system       Do not restore UFW/Fail2Ban/cron/systemd/Docker config
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    --skip-system) SKIP_SYSTEM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1"; usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo/root."; exit 1; }
[[ -n "$BACKUP_DIR" ]] || { echo "ERROR: --backup-dir is required."; exit 1; }

BACKUP_DIR="$(realpath "$BACKUP_DIR")"
[[ -d "$BACKUP_DIR" ]] || { echo "ERROR: backup not found: $BACKUP_DIR"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command missing: $1"
    exit 1
  }
}

need_file() {
  [[ -f "$1" ]] || {
    echo "ERROR: required backup file missing: $1"
    exit 1
  }
}

need_dir() {
  [[ -d "$1" ]] || {
    echo "ERROR: required backup directory missing: $1"
    exit 1
  }
}

confirm() {
  [[ "$YES" -eq 1 ]] && return 0
  read -r -p "$1 [yes/NO]: " answer
  [[ "$answer" == "yes" ]]
}

restore_tar() {
  local archive="$1"
  local destination="$2"
  need_file "$archive"
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination"
}

compose_up() {
  local file="$1"
  need_file "$file"
  docker compose -f "$file" up -d
}

wait_container() {
  local container="$1"
  local seconds="${2:-120}"
  local end=$((SECONDS + seconds))
  while (( SECONDS < end )); do
    if docker inspect "$container" >/dev/null 2>&1; then
      local state
      state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
      [[ "$state" == "running" ]] && return 0
    fi
    sleep 2
  done
  echo "ERROR: container did not become running: $container"
  docker ps -a --filter "name=^${container}$" || true
  exit 1
}

wait_pg() {
  local end=$((SECONDS + 120))
  while (( SECONDS < end )); do
    if docker exec postgres pg_isready -U admin -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: PostgreSQL did not become ready."
  docker logs --tail 80 postgres || true
  exit 1
}

verify_structure() {
  echo "Checking backup structure..."
  need_file "$BACKUP_DIR/manifest/checksums.sha256"
  need_file "$BACKUP_DIR/postgres/globals.sql"
  need_file "$BACKUP_DIR/postgres/n8n_konten.dump"
  need_file "$BACKUP_DIR/postgres/postgres.dump"
  need_file "$BACKUP_DIR/docker/data/n8n-data.tar.gz"
  need_file "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz"
  need_file "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz"
  need_file "$BACKUP_DIR/docker/data/npm-data.tar.gz"
  need_file "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz"
  need_file "$BACKUP_DIR/docker/data/dockge-data.tar.gz"
  need_file "$BACKUP_DIR/docker/volumes/portainer_portainer_data.tar.gz"
  need_file "$BACKUP_DIR/docker/volumes/n8n-sandbox_sandbox-tls.tar.gz"
  need_file "$BACKUP_DIR/services/render-service/render-service.tar.gz"
  need_file "$BACKUP_DIR/services/tts-service/tts-service.tar.gz"
  need_file "$BACKUP_DIR/services/render-service/render-service.service"
  need_file "$BACKUP_DIR/services/tts-service/tts-service.service"
  need_file "$BACKUP_DIR/services/render-service/requirements.freeze.txt"
  need_file "$BACKUP_DIR/services/tts-service/requirements.freeze.txt"
  need_file "$BACKUP_DIR/docker/compose/stacks/n8n/compose.yaml"
  need_file "$BACKUP_DIR/docker/compose/stacks/postgres/compose.yaml"
  need_file "$BACKUP_DIR/docker/compose/stacks/n8n-sandbox/compose.yaml"
  need_file "$BACKUP_DIR/docker/compose/npm/compose.yaml"
  need_file "$BACKUP_DIR/docker/compose/cloudbeaver/compose.yaml" 2>/dev/null || true
  need_file "$BACKUP_DIR/docker/compose/stacks/cloudbeaver/compose.yaml"
  need_file "$BACKUP_DIR/docker/compose/stacks/uptime-kuma/compose.yaml"
  need_file "$BACKUP_DIR/docker/compose/dockge/compose.yaml"
  need_file "$BACKUP_DIR/docker/compose/content-factory-docker/portainer/docker-compose.yml"
  echo "Backup structure: OK"
}

echo "============================================================"
echo " VPS FULL RESTORE v3"
echo "============================================================"
echo "Backup: $BACKUP_DIR"
echo

need_cmd tar
need_cmd sha256sum
need_cmd realpath
need_cmd systemctl
need_cmd docker
need_cmd curl

verify_structure

# Always verify from inside the backup directory so relative checksum paths work.
echo "[1/12] Verifying SHA-256..."
(
  cd "$BACKUP_DIR"
  sha256sum -c manifest/checksums.sha256
)
echo "Checksum verification: OK"

# Verify archive contents without extracting them.
echo "[2/12] Verifying archive structure..."
tar -tzf "$BACKUP_DIR/docker/data/n8n-data.tar.gz" | grep -qx 'data/'
tar -tzf "$BACKUP_DIR/services/render-service/render-service.tar.gz" | grep -qx 'render-service/'
tar -tzf "$BACKUP_DIR/services/tts-service/tts-service.tar.gz" | grep -qx 'tts-service/'
echo "Archive structure: OK"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "============================================================"
  echo " DRY-RUN PASSED"
  echo "============================================================"
  echo "No files, containers, databases, services, or firewall rules were changed."
  exit 0
fi

echo
 echo "WARNING: this is a REAL RESTORE."
echo "Use this on a rebuilt/fresh VPS whenever possible."
echo "SSH configuration will NOT be restored automatically."
confirm "Continue with REAL RESTORE?" || { echo "Cancelled."; exit 0; }

# Fresh target directories. Existing application data is moved aside instead
# of deleted, providing a rollback point on the target VPS.
STAMP="$(date '+%Y%m%d-%H%M%S')"
QUARANTINE="/opt/recovery-pre-restore-${STAMP}"

# Refuse accidental restore onto a non-empty production host unless explicitly
# confirmed above. We do not delete existing application directories.
echo "[3/12] Preparing target directories..."
mkdir -p "$QUARANTINE"

for path in \
  /opt/stacks/n8n/data \
  /opt/stacks/postgres/data \
  /opt/stacks/cloudbeaver/data \
  /opt/stacks/uptime-kuma/data \
  /opt/npm/data \
  /opt/npm/letsencrypt \
  /opt/dockge/data \
  /opt/render-service \
  /opt/tts-service
 do
  if [[ -e "$path" ]]; then
    mkdir -p "$QUARANTINE$(dirname "$path")"
    mv "$path" "$QUARANTINE$path"
  fi
done

mkdir -p /opt/stacks /opt/npm /opt/dockge /opt/content-factory/docker /opt/scripts

# Restore stack definitions and environment files.
echo "[4/12] Restoring Compose/configuration..."
cp -a "$BACKUP_DIR/docker/compose/stacks/." /opt/stacks/
cp -a "$BACKUP_DIR/docker/compose/npm/." /opt/npm/
cp -a "$BACKUP_DIR/docker/compose/dockge/." /opt/dockge/
cp -a "$BACKUP_DIR/docker/compose/content-factory-docker/." /opt/content-factory/docker/

# Restore application data. Archives contain their top-level data directory.
echo "[5/12] Restoring application data..."
restore_tar "$BACKUP_DIR/docker/data/n8n-data.tar.gz" /opt/stacks/n8n
restore_tar "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz" /opt/stacks/cloudbeaver
restore_tar "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz" /opt/stacks/uptime-kuma
restore_tar "$BACKUP_DIR/docker/data/npm-data.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/dockge-data.tar.gz" /opt/dockge

# Restore named Docker volumes.
echo "[6/12] Restoring Docker volumes..."
docker volume create portainer_portainer_data >/dev/null

docker run --rm \
  -v portainer_portainer_data:/target \
  -v "$BACKUP_DIR/docker/volumes":/backup:ro \
  alpine sh -c 'tar xzf /backup/portainer_portainer_data.tar.gz -C /target'

docker volume create n8n-sandbox_sandbox-tls >/dev/null

docker run --rm \
  -v n8n-sandbox_sandbox-tls:/target \
  -v "$BACKUP_DIR/docker/volumes":/backup:ro \
  alpine sh -c 'tar xzf /backup/n8n-sandbox_sandbox-tls.tar.gz -C /target'

# Ensure the proxy network exists before bringing up stacks.
echo "[7/12] Preparing Docker network..."
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy >/dev/null

# PostgreSQL must be restored before n8n.
echo "[8/12] Restoring PostgreSQL..."
compose_up /opt/stacks/postgres/compose.yaml
wait_container postgres
wait_pg

# Restore global roles. Existing-role notices/errors can occur when the base
# image already created admin; role existence is checked explicitly below.
docker exec -i postgres psql -U admin -d postgres < "$BACKUP_DIR/postgres/globals.sql" >/tmp/recovery-globals.log 2>&1 || true

if ! docker exec postgres psql -U admin -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='n8n'" | grep -q '^1$'; then
  echo "ERROR: PostgreSQL role n8n is missing after globals restore."
  cat /tmp/recovery-globals.log || true
  exit 1
fi

if ! docker exec postgres psql -U admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='n8n_konten'" | grep -q '^1$'; then
  docker exec postgres psql -U admin -d postgres -c 'CREATE DATABASE n8n_konten OWNER n8n;'
fi

docker cp "$BACKUP_DIR/postgres/n8n_konten.dump" postgres:/tmp/n8n_konten.dump
docker exec postgres pg_restore \
  -U admin \
  -d n8n_konten \
  --clean \
  --if-exists \
  --no-owner \
  --exit-on-error \
  /tmp/n8n_konten.dump
docker exec postgres rm -f /tmp/n8n_konten.dump

# The default postgres database contains little application data on this VPS;
# restore it only after n8n has been restored and surface any real error.
docker cp "$BACKUP_DIR/postgres/postgres.dump" postgres:/tmp/postgres.dump
docker exec postgres pg_restore \
  -U admin \
  -d postgres \
  --clean \
  --if-exists \
  --no-owner \
  --exit-on-error \
  /tmp/postgres.dump
docker exec postgres rm -f /tmp/postgres.dump

rm -f /tmp/recovery-globals.log

# Restore native services exactly as archived first.
echo "[9/12] Restoring Render/TTS services..."
restore_tar "$BACKUP_DIR/services/render-service/render-service.tar.gz" /opt
restore_tar "$BACKUP_DIR/services/tts-service/tts-service.tar.gz" /opt

cp "$BACKUP_DIR/services/render-service/render-service.service" /etc/systemd/system/render-service.service
cp "$BACKUP_DIR/services/tts-service/tts-service.service" /etc/systemd/system/tts-service.service

if id zkonten >/dev/null 2>&1; then
  chown -R zkonten:zkonten /opt/render-service /opt/tts-service
fi

# Restore selected system configuration. SSH is deliberately excluded.
echo "[10/12] Restoring system configuration..."
if [[ "$SKIP_SYSTEM" -eq 0 ]]; then
  tar -xzf "$BACKUP_DIR/system/docker-config.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/ufw.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/fail2ban.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/cron.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/systemd.tar.gz" -C /etc
  echo "SSH config: NOT RESTORED (intentional)"
else
  echo "System configuration: SKIPPED"
fi

systemctl daemon-reload

# Start application stacks only after PostgreSQL and data are ready.
echo "[11/12] Starting application stacks..."
compose_up /opt/stacks/n8n-sandbox/compose.yaml
compose_up /opt/stacks/n8n/compose.yaml
compose_up /opt/stacks/cloudbeaver/compose.yaml
compose_up /opt/stacks/uptime-kuma/compose.yaml
compose_up /opt/dockge/compose.yaml
compose_up /opt/content-factory/docker/portainer/docker-compose.yml
compose_up /opt/npm/compose.yaml

# Native services.
systemctl enable render-service.service tts-service.service
systemctl restart render-service.service
systemctl restart tts-service.service

# Health checks.
echo "[12/12] Running health checks..."
sleep 5

FAIL=0

check_container() {
  local name="$1"
  if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
    echo "$name: RUNNING"
  else
    echo "$name: FAILED"
    FAIL=1
  fi
}

for c in postgres n8n cloudbeaver uptime-kuma dockge portainer npm; do
  check_container "$c"
done

if docker inspect sandbox-api >/dev/null 2>&1; then
  check_container sandbox-api
fi

if docker exec postgres pg_isready -U admin -d postgres >/dev/null 2>&1; then
  echo "PostgreSQL: READY"
else
  echo "PostgreSQL: FAILED"
  FAIL=1
fi

if docker exec postgres psql -U admin -d n8n_konten -tAc 'SELECT count(*) FROM "workflow_entity"' >/tmp/n8n-count.txt 2>/dev/null; then
  echo "n8n database: ACCESSIBLE (workflow rows: $(tr -d ' ' < /tmp/n8n-count.txt))"
else
  echo "n8n database: FAILED"
  FAIL=1
fi
rm -f /tmp/n8n-count.txt

if curl -fsS http://127.0.0.1:5006/health >/dev/null 2>&1; then
  echo "Render /health: OK"
else
  echo "Render /health: FAILED"
  FAIL=1
fi

if systemctl is-active --quiet tts-service.service; then
  echo "TTS service: ACTIVE"
else
  echo "TTS service: FAILED"
  FAIL=1
fi

if curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
  echo "n8n /healthz: OK"
else
  echo "n8n /healthz: not responding yet"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "============================================================"
  echo " RESTORE FINISHED WITH ERRORS"
  echo "============================================================"
  echo "Pre-restore data was moved to: $QUARANTINE"
  echo "DO NOT delete that directory until the restored system is verified."
  exit 1
fi

echo
 echo "============================================================"
echo " RESTORE FINISHED SUCCESSFULLY"
echo "============================================================"
echo "Backup: $BACKUP_DIR"
echo "Rollback data: $QUARANTINE"
echo
 echo "Manual checks still required:"
echo "1. Login to n8n and verify workflows/credentials."
echo "2. Verify NPM Proxy Hosts and SSL certificates."
echo "3. Test Render /health and one real render."
echo "4. Test TTS service."
echo "5. Verify SSH before closing the current session."

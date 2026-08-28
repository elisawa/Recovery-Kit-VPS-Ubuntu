#!/usr/bin/env bash
set -Eeuo pipefail

# VPS Recovery Kit - Restore v4
# Safe by default: --dry-run changes nothing.
# SSH configuration is never restored automatically.

BACKUP_DIR=""
DRY_RUN=0
YES=0
SKIP_SYSTEM=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./restore-vps.sh --backup-dir /path/to/backup --dry-run
  sudo ./restore-vps.sh --backup-dir /path/to/backup

Options:
  --backup-dir PATH   Recovery backup directory (required)
  --dry-run           Validate backup and host only; change nothing
  --yes               Skip restore confirmation
  --skip-system       Do not restore Docker/UFW/Fail2Ban/cron/systemd
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

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command missing: $1"; exit 1; }; }
need_file() { [[ -f "$1" ]] || { echo "ERROR: required backup file missing: $1"; exit 1; }; }
need_dir() { [[ -d "$1" ]] || { echo "ERROR: required backup directory missing: $1"; exit 1; }; }

need_cmd tar
need_cmd sha256sum
need_cmd docker
need_cmd systemctl
need_cmd curl

CHECKSUMS="$BACKUP_DIR/manifest/checksums.sha256"
need_file "$CHECKSUMS"

required_files=(
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

echo "============================================================"
echo " VPS FULL RESTORE v4"
echo "============================================================"
echo "Backup: $BACKUP_DIR"
echo

echo "Checking backup structure..."
for f in "${required_files[@]}"; do need_file "$f"; done

echo "Backup structure: OK"

echo

echo "Checking archive readability..."
for a in \
  "$BACKUP_DIR/docker/data/n8n-data.tar.gz" \
  "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz" \
  "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz" \
  "$BACKUP_DIR/docker/data/npm-data.tar.gz" \
  "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz" \
  "$BACKUP_DIR/docker/data/dockge-data.tar.gz" \
  "$BACKUP_DIR/docker/volumes/portainer_portainer_data.tar.gz" \
  "$BACKUP_DIR/docker/volumes/n8n-sandbox_sandbox-tls.tar.gz" \
  "$BACKUP_DIR/services/render-service/render-service.tar.gz" \
  "$BACKUP_DIR/services/tts-service/tts-service.tar.gz"; do
  tar -tzf "$a" >/dev/null
  echo "  OK: $(basename "$a")"
done

echo
echo "Checking SHA-256..."
(
  cd "$BACKUP_DIR"
  sha256sum -c "$CHECKSUMS" >/tmp/recovery-sha256.log
)
tail -n 3 /tmp/recovery-sha256.log
echo "Checksum verification: OK"
rm -f /tmp/recovery-sha256.log

echo
echo "Checking Docker image availability/digests..."
if docker info >/dev/null 2>&1; then
  awk 'NR>1 && $1 !~ /^=====|^$/ && $1 !~ /^\// {print $1 ":" $2}' "$BACKUP_DIR/manifest/docker-images.txt" 2>/dev/null | while read -r image; do
    [[ -n "$image" ]] || continue
    if docker image inspect "$image" >/dev/null 2>&1; then
      echo "  PRESENT: $image"
    else
      echo "  MISSING: $image"
    fi
done
else
  echo "  Docker daemon is not available; restore host must install/start Docker first."
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
echo "============================================================"
  echo " DRY-RUN PASSED"
  echo "============================================================"
  echo "No files, containers, databases, services, or firewall rules were changed."
  exit 0
fi

confirm() {
  [[ "$YES" -eq 1 ]] && return 0
  read -r -p "$1 [yes/NO]: " answer
  [[ "$answer" == "yes" ]]
}

confirm "Continue with RESTORE?" || { echo "Cancelled."; exit 0; }

restore_tar() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  tar -xzf "$archive" -C "$dest"
}

compose_up() {
  local f="$1"
  docker compose -f "$f" up -d
}

wait_pg() {
  for i in {1..60}; do
    if docker exec postgres pg_isready -U admin -d postgres >/dev/null 2>&1; then return 0; fi
    sleep 2
done
  echo "ERROR: PostgreSQL did not become ready."; exit 1
}

echo
echo "WARNING: live restore mode will modify this VPS."

# Restore compose definitions to their exact backup paths.
mkdir -p /opt/stacks /opt/npm /opt/dockge /opt/content-factory/docker
cp -a "$BACKUP_DIR/docker/compose/stacks/." /opt/stacks/
cp -a "$BACKUP_DIR/docker/compose/npm/." /opt/npm/
cp -a "$BACKUP_DIR/docker/compose/dockge/." /opt/dockge/
cp -a "$BACKUP_DIR/docker/compose/content-factory-docker/." /opt/content-factory/docker/

# Restore application data. Archives contain their top-level data/ directory.
restore_tar "$BACKUP_DIR/docker/data/n8n-data.tar.gz" /opt/stacks/n8n
restore_tar "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz" /opt/stacks/cloudbeaver
restore_tar "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz" /opt/stacks/uptime-kuma
restore_tar "$BACKUP_DIR/docker/data/npm-data.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/dockge-data.tar.gz" /opt/dockge

# Docker volumes.
docker volume create portainer_portainer_data >/dev/null
docker run --rm -v portainer_portainer_data:/target -v "$BACKUP_DIR/docker/volumes":/backup:ro alpine sh -c 'tar xzf /backup/portainer_portainer_data.tar.gz -C /target'
docker volume create n8n-sandbox_sandbox-tls >/dev/null
docker run --rm -v n8n-sandbox_sandbox-tls:/target -v "$BACKUP_DIR/docker/volumes":/backup:ro alpine sh -c 'tar xzf /backup/n8n-sandbox_sandbox-tls.tar.gz -C /target'

docker network inspect proxy >/dev/null 2>&1 || docker network create proxy >/dev/null

# PostgreSQL first.
compose_up /opt/stacks/postgres/compose.yaml
wait_pg
docker exec -i postgres psql -U admin -d postgres < "$BACKUP_DIR/postgres/globals.sql" || true
if ! docker exec postgres psql -U admin -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='n8n'" | grep -q 1; then
  echo "ERROR: PostgreSQL role n8n was not restored."; exit 1
fi
if ! docker exec postgres psql -U admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='n8n_konten'" | grep -q 1; then
  docker exec postgres psql -U admin -d postgres -c 'CREATE DATABASE n8n_konten OWNER n8n;'
fi
docker cp "$BACKUP_DIR/postgres/n8n_konten.dump" postgres:/tmp/n8n_konten.dump
docker exec postgres pg_restore -U admin -d n8n_konten --clean --if-exists --no-owner --exit-on-error /tmp/n8n_konten.dump
docker exec postgres rm -f /tmp/n8n_konten.dump

docker cp "$BACKUP_DIR/postgres/postgres.dump" postgres:/tmp/postgres.dump
docker exec postgres pg_restore -U admin -d postgres --clean --if-exists --no-owner /tmp/postgres.dump || true
docker exec postgres rm -f /tmp/postgres.dump

# Native services: restore archive under /opt, preserving /opt/render-service and /opt/tts-service.
rm -rf /opt/render-service /opt/tts-service
restore_tar "$BACKUP_DIR/services/render-service/render-service.tar.gz" /opt
restore_tar "$BACKUP_DIR/services/tts-service/tts-service.tar.gz" /opt
cp "$BACKUP_DIR/services/render-service/render-service.service" /etc/systemd/system/render-service.service
cp "$BACKUP_DIR/services/tts-service/tts-service.service" /etc/systemd/system/tts-service.service
id zkonten >/dev/null 2>&1 && chown -R zkonten:zkonten /opt/render-service /opt/tts-service

# System config except SSH.
if [[ "$SKIP_SYSTEM" -eq 0 ]]; then
  tar -xzf "$BACKUP_DIR/system/docker-config.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/ufw.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/fail2ban.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/cron.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/systemd.tar.gz" -C /etc
  echo "SSH config intentionally NOT restored."
fi

systemctl daemon-reload
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

sleep 5
echo
echo "===== RESTORE HEALTH ====="
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
echo
docker network inspect proxy --format '{{range .Containers}}{{println .Name}}{{end}}' || true
echo
if docker exec postgres pg_isready -U admin -d postgres >/dev/null 2>&1; then echo "PostgreSQL: OK"; else echo "PostgreSQL: FAILED"; fi
if curl -fsS http://127.0.0.1:5006/health >/dev/null 2>&1; then echo "Render /health: OK"; else echo "Render /health: FAILED"; fi
if systemctl is-active --quiet tts-service.service; then echo "TTS service: OK"; else echo "TTS service: FAILED"; fi
if curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1; then echo "n8n /healthz: OK"; else echo "n8n /healthz: not responding"; fi

echo
echo "============================================================"
echo " RESTORE FINISHED"
echo "============================================================"
echo "Verify n8n login/workflows, NPM Proxy Hosts/SSL, Render/TTS logs, and SSH before closing the session."

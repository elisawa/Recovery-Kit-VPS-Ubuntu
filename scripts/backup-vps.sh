#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# VPS FULL BACKUP
# Host: Content Factory / n8n / Render / TTS
# Backup name: vps-backup-YYYY-MM-DD HH.MM-FRUIT
# Keeps only the 2 newest backups.
# Can be run from any working directory.
# ============================================================

BACKUP_ROOT="/opt/backup/vps"
export TZ="Asia/Jakarta"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'USAGE'
Usage:
  sudo backup-vps

Creates a VPS recovery backup under /opt/backup/vps using:
  vps-backup-YYYY-MM-DD HH.MM-FRUIT

Only the 2 newest vps-backup-* directories are retained.
USAGE
    exit 0
fi

FRUITS=(
    "JERUK" "MANGGA" "DURIAN" "SALAK" "RAMBUTAN"
    "MANGGIS" "PISANG" "PEPAYA" "NANAS" "SEMANGKA"
    "JAMBU" "SIRSAK" "NANGKA" "BELIMBING" "ALPUKAT"
    "KELAPA" "DUKU" "LANGSAT" "MARKISA" "APEL"
)

TIMESTAMP="$(date '+%Y-%m-%d %H.%M')"
FRUIT="${FRUITS[$((RANDOM % ${#FRUITS[@]}))]}"
BACKUP_NAME="vps-backup-${TIMESTAMP}-${FRUIT}"
BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_NAME}"

# Hindari overwrite bila backup dibuat pada menit yang sama.
if [[ -e "$BACKUP_DIR" ]]; then
    n=2
    while [[ -e "${BACKUP_DIR}-${n}" ]]; do
        ((n++))
    done
    BACKUP_DIR="${BACKUP_DIR}-${n}"
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: jalankan dengan sudo."
    exit 1
fi

mkdir -p "$BACKUP_DIR"/{manifest,docker,postgres,services,system}

echo "============================================================"
echo " VPS FULL BACKUP"
echo "============================================================"
echo "Backup : ${BACKUP_DIR}"
echo

echo "[1/10] Membuat manifest sistem..."
{
    echo "BACKUP_NAME=${BACKUP_NAME}"
    echo "BACKUP_DATE=$(date -Is)"
    echo "HOSTNAME=$(hostname)"
    echo; echo "===== OS ====="; cat /etc/os-release
    echo; echo "===== KERNEL ====="; uname -a
    echo; echo "===== DISK ====="; df -hT
    echo; echo "===== MEMORY ====="; free -h
    echo; echo "===== DOCKER ====="; docker --version; docker compose version 2>/dev/null || true
    echo; echo "===== CONTAINERS ====="; docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    echo; echo "===== VOLUMES ====="; docker volume ls
    echo; echo "===== NETWORKS ====="; docker network ls
    echo; echo "===== PROXY NETWORK ====="; docker network inspect proxy 2>/dev/null || true
} > "$BACKUP_DIR/manifest/system.txt"

echo "[2/10] Backup Docker Compose dan konfigurasi..."
mkdir -p "$BACKUP_DIR/docker/compose"
cp -a /opt/stacks "$BACKUP_DIR/docker/compose/" 2>/dev/null || true
cp -a /opt/npm "$BACKUP_DIR/docker/compose/" 2>/dev/null || true
cp -a /opt/dockge "$BACKUP_DIR/docker/compose/" 2>/dev/null || true
cp -a /opt/content-factory/docker "$BACKUP_DIR/docker/compose/content-factory-docker" 2>/dev/null || true
rm -rf "$BACKUP_DIR/docker/compose/stacks/n8n/data"
rm -rf "$BACKUP_DIR/docker/compose/stacks/postgres/data"
rm -rf "$BACKUP_DIR/docker/compose/stacks/cloudbeaver/data"
rm -rf "$BACKUP_DIR/docker/compose/stacks/uptime-kuma/data"
rm -rf "$BACKUP_DIR/docker/compose/stacks/npm/data"
rm -rf "$BACKUP_DIR/docker/compose/stacks/npm/letsencrypt"
rm -rf "$BACKUP_DIR/docker/compose/stacks/dockge/data"
rm -rf "$BACKUP_DIR/docker/compose/npm/data"
rm -rf "$BACKUP_DIR/docker/compose/npm/letsencrypt"
rm -rf "$BACKUP_DIR/docker/compose/dockge/data"

echo "[3/10] Backup data Docker..."
mkdir -p "$BACKUP_DIR/docker/data"
tar -czf "$BACKUP_DIR/docker/data/n8n-data.tar.gz" -C /opt/stacks/n8n data
tar -czf "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz" -C /opt/stacks/cloudbeaver data
tar -czf "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz" -C /opt/stacks/uptime-kuma data
tar -czf "$BACKUP_DIR/docker/data/npm-data.tar.gz" -C /opt/npm data
tar -czf "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz" -C /opt/npm letsencrypt
tar -czf "$BACKUP_DIR/docker/data/dockge-data.tar.gz" -C /opt/dockge data

echo "[4/10] Backup Docker volumes..."
mkdir -p "$BACKUP_DIR/docker/volumes"
if docker volume inspect portainer_portainer_data >/dev/null 2>&1; then
    docker run --rm -v portainer_portainer_data:/source:ro -v "$BACKUP_DIR/docker/volumes":/backup alpine sh -c 'tar czf /backup/portainer_portainer_data.tar.gz -C /source .'
fi
if docker volume inspect n8n-sandbox_sandbox-tls >/dev/null 2>&1; then
    docker run --rm -v n8n-sandbox_sandbox-tls:/source:ro -v "$BACKUP_DIR/docker/volumes":/backup alpine sh -c 'tar czf /backup/n8n-sandbox_sandbox-tls.tar.gz -C /source .'
fi

echo "[5/10] Backup PostgreSQL..."
mkdir -p "$BACKUP_DIR/postgres"
docker exec postgres pg_dumpall -U admin --globals-only > "$BACKUP_DIR/postgres/globals.sql"
docker exec postgres pg_dump -U admin -d n8n_konten --format=custom --file=/tmp/n8n_konten.dump
docker cp postgres:/tmp/n8n_konten.dump "$BACKUP_DIR/postgres/n8n_konten.dump"
docker exec postgres rm -f /tmp/n8n_konten.dump
docker exec postgres pg_dump -U admin -d postgres --format=custom --file=/tmp/postgres.dump
docker cp postgres:/tmp/postgres.dump "$BACKUP_DIR/postgres/postgres.dump"
docker exec postgres rm -f /tmp/postgres.dump
docker exec postgres psql -U admin -d postgres -c '\l' > "$BACKUP_DIR/postgres/database-list.txt"
docker exec postgres psql -U admin -d postgres -c '\du' > "$BACKUP_DIR/postgres/role-list.txt"

echo "[6/10] Backup Render Service..."
mkdir -p "$BACKUP_DIR/services/render-service"
tar -czf "$BACKUP_DIR/services/render-service/render-service.tar.gz" --exclude='render.log' --exclude='__pycache__' -C /opt render-service
systemctl cat render-service.service > "$BACKUP_DIR/services/render-service/render-service.service"
if [[ -x /opt/render-service/venv/bin/pip ]]; then /opt/render-service/venv/bin/pip freeze > "$BACKUP_DIR/services/render-service/requirements.freeze.txt" || true; fi

echo "[7/10] Backup TTS Service..."
mkdir -p "$BACKUP_DIR/services/tts-service"
tar -czf "$BACKUP_DIR/services/tts-service/tts-service.tar.gz" --exclude='output' --exclude='__pycache__' -C /opt tts-service
systemctl cat tts-service.service > "$BACKUP_DIR/services/tts-service/tts-service.service"
if [[ -x /opt/tts-service/venv/bin/pip ]]; then /opt/tts-service/venv/bin/pip freeze > "$BACKUP_DIR/services/tts-service/requirements.freeze.txt" || true; fi

echo "[8/10] Backup konfigurasi sistem..."
mkdir -p "$BACKUP_DIR/system"
tar -czf "$BACKUP_DIR/system/systemd.tar.gz" -C /etc systemd/system
tar -czf "$BACKUP_DIR/system/ssh.tar.gz" -C /etc ssh
tar -czf "$BACKUP_DIR/system/ufw.tar.gz" -C /etc ufw
if [[ -d /etc/fail2ban ]]; then tar -czf "$BACKUP_DIR/system/fail2ban.tar.gz" -C /etc fail2ban; fi
tar -czf "$BACKUP_DIR/system/docker-config.tar.gz" -C /etc docker
tar -czf "$BACKUP_DIR/system/cron.tar.gz" -C /etc cron.d crontab
systemctl list-unit-files > "$BACKUP_DIR/system/systemd-unit-files.txt"
systemctl list-units --type=service --all > "$BACKUP_DIR/system/systemd-services.txt"
ufw status verbose > "$BACKUP_DIR/system/ufw-status.txt" 2>&1 || true

echo "[9/10] Mencatat Docker image dan digest..."
{
    echo "===== docker images ====="
    docker images --digests
    echo
    echo "===== container image IDs ====="
    for c in n8n postgres npm cloudbeaver portainer dockge uptime-kuma; do
        if docker inspect "$c" >/dev/null 2>&1; then
            docker inspect "$c" --format '{{.Name}} | image={{.Config.Image}} | image_id={{.Image}}'
        fi
    done
    echo
    echo "===== sandbox containers ====="
    docker ps -a --format '{{.Names}}' | while read -r c; do
        case "$c" in
            sandbox*) docker inspect "$c" --format '{{.Name}} | image={{.Config.Image}} | image_id={{.Image}}';;
        esac
    done
} > "$BACKUP_DIR/manifest/docker-images.txt"
mkdir -p "$BACKUP_DIR/manifest/compose-rendered"
for compose in \
    /opt/stacks/n8n-sandbox/compose.yaml \
    /opt/stacks/n8n/compose.yaml \
    /opt/stacks/postgres/compose.yaml \
    /opt/stacks/uptime-kuma/compose.yaml \
    /opt/stacks/cloudbeaver/compose.yaml \
    /opt/dockge/compose.yaml \
    /opt/content-factory/docker/portainer/docker-compose.yml \
    /opt/npm/compose.yaml
do
    if [[ -f "$compose" ]]; then
        name="$(basename "$(dirname "$compose")")"
        docker compose -f "$compose" config 2>/dev/null |
        sed -E \
            -e 's/(PASSWORD|API_KEY|TOKEN|SECRET|KEY):[[:space:]]*[^[:space:]]+/\1: "***REDACTED***"/Ig' \
            -e 's/(PASSWORD|API_KEY|TOKEN|SECRET|KEY)=([^[:space:]]+)/\1=***REDACTED***/Ig' \
            > "$BACKUP_DIR/manifest/compose-rendered/${name}.yaml" || true
    fi
done

echo "[10/10] Membuat checksum..."
(
    cd "$BACKUP_DIR"
    find . -type f ! -name 'checksums.sha256' -print0 | sort -z | xargs -0 sha256sum
) > "$BACKUP_DIR/manifest/checksums.sha256"
{
    echo "============================================================"
    echo "VPS RECOVERY BACKUP"
    echo "============================================================"
    echo "Backup Name: ${BACKUP_NAME}"
    echo "Created     : $(date -Is)"
    echo "Host        : $(hostname)"
    echo "Backup      : $BACKUP_DIR"
    echo
    echo "===== BACKUP SIZE ====="
    du -sh "$BACKUP_DIR"
    echo
    echo "===== FILE COUNT ====="
    find "$BACKUP_DIR" -type f | wc -l
    echo
    echo "===== TOP FILES ====="
    du -ah "$BACKUP_DIR" | sort -h | tail -20
} > "$BACKUP_DIR/manifest/README.txt"

echo
echo "============================================================"
echo " BACKUP SELESAI"
echo "============================================================"
echo
echo "Lokasi:"
echo "  $BACKUP_DIR"
echo
echo "Ukuran:"
du -sh "$BACKUP_DIR"
echo
echo "File:"
find "$BACKUP_DIR" -type f | wc -l
echo
echo "Checksum:"
echo "  $BACKUP_DIR/manifest/checksums.sha256"
echo
echo "PENTING:"
echo "Backup ini masih berada di VPS."
echo "Salin backup ini ke STORAGE DI LUAR VPS."

echo
echo "[CLEANUP] Menyimpan hanya 2 backup terbaru..."
mapfile -t OLD_BACKUPS < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'vps-backup-*' -printf '%T@ %p\n' | sort -nr | tail -n +3 | cut -d' ' -f2-)
for old in "${OLD_BACKUPS[@]}"; do
    [[ -n "$old" ]] || continue
    echo "  Removing: $old"
    rm -rf -- "$old"
done

echo "  Backup count: $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'vps-backup-*' | wc -l)"

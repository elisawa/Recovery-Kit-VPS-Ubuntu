# Recovery Kit VPS Ubuntu

Recovery kit untuk membuat backup dan membangun kembali VPS Ubuntu dari backup yang sudah diverifikasi.

## 1. Prinsip keselamatan

- **Selalu jalankan restore dengan `--dry-run` terlebih dahulu.**
- Jangan menjalankan live restore pada VPS production tanpa rencana rollback.
- Simpan backup **di VPS dan di luar VPS**. Backup di VPS saja bukan disaster recovery.
- Jangan menghapus backup external sampai backup pengganti sudah diverifikasi.
- **SSH tidak pernah dipulihkan otomatis** oleh restore script.
- Live restore mengubah Docker, PostgreSQL, systemd, dan file aplikasi.
- Sebelum live restore, pastikan sesi SSH aktif dan akses SSH ke VPS baru sudah terbukti.
- Jangan menjalankan `--restore-system` kecuali memang diperlukan dan konfigurasi host sudah ditinjau.

---

# 2. Struktur Recovery Kit

```text
Recovery-Kit-VPS-Ubuntu/
├── scripts/
│   ├── backup-vps.sh
│   ├── backup-vps
│   └── restore-vps.sh
└── README.md
```

## Script backup

`backup-vps.sh` membuat backup di `/opt/backup/vps/`.

Nama backup menggunakan WIB dan **tanpa spasi**:

```text
vps-backup-YYYY-MM-DD-HH.MM-BUAH
```

Contoh:

```text
vps-backup-2026-08-28-22.30-KELAPA
```

Script otomatis mempertahankan **2 backup terbaru** dengan pola `vps-backup-*`.

Command yang direkomendasikan:

```bash
sudo backup-vps
sudo backup-vps --help
```

Script dapat dijalankan dari direktori mana pun karena menggunakan path absolut.

---

# 3. CARA BACKUP VPS

## 3.1 Syarat sebelum backup

Backup harus dijalankan pada VPS yang masih sehat dan memiliki:

- Ubuntu/Linux host.
- Docker aktif.
- Docker Compose tersedia melalui `docker compose`.
- Container PostgreSQL bernama `postgres` aktif.
- Database `n8n_konten` tersedia.
- `render-service.service` dan `tts-service.service` tersedia jika digunakan.
- User `zkonten` tersedia jika service Render/TTS menggunakannya.
- Ruang disk cukup.
- `/opt/backup/vps` dapat ditulis oleh root.

## 3.2 Install/update command backup

```bash
sudo curl -fsSL https://raw.githubusercontent.com/elisawa/Recovery-Kit-VPS-Ubuntu/main/scripts/backup-vps.sh -o /usr/local/bin/backup-vps
sudo chmod 700 /usr/local/bin/backup-vps
sudo bash -n /usr/local/bin/backup-vps
```

Kemudian:

```bash
sudo backup-vps --help
```

`--help` **tidak membuat backup**.

## 3.3 Jalankan backup

```bash
sudo backup-vps
```

Backup mencakup Docker Compose/configuration, n8n data, CloudBeaver, Uptime Kuma, NPM dan Let's Encrypt, Dockge, Portainer volume, n8n sandbox TLS volume, PostgreSQL globals/roles dan dumps, Render, TTS, systemd, SSH archive, UFW, Fail2Ban jika tersedia, Docker configuration, cron, Docker image information/digests, rendered Compose manifests, dan SHA-256 checksum.

## 3.4 Verifikasi hasil backup

```bash
sudo find /opt/backup/vps -mindepth 1 -maxdepth 1 -type d -name 'vps-backup-*' -printf '%f\n' | sort -r
sudo du -sh /opt/backup/vps/vps-backup-*
```

Pastikan hanya **2 backup terbaru** yang tersisa.

Backup **wajib disalin ke storage di luar VPS** sebelum dianggap sebagai disaster recovery yang aman.

---

# 4. CARA RESTORE — VPS BARU DARI NOL

Prosedur ini digunakan ketika VPS lama hilang/rusak dan kita membangun VPS pengganti.

## 4.1 Provision VPS baru

Gunakan VPS baru dengan spesifikasi minimal setara VPS lama atau lebih besar, terutama CPU, RAM, dan disk.

Gunakan **Ubuntu Server LTS** yang kompatibel dengan environment lama. Recovery Kit tidak menginstal Ubuntu; Ubuntu harus sudah terpasang dan VPS harus dapat diakses melalui SSH.

Minimal yang harus tersedia:

- VPS baru dengan public IP jika service membutuhkan internet.
- Ubuntu Server LTS sudah terinstall.
- Akses root atau user dengan `sudo`.
- SSH aktif.
- Internet aktif.
- Disk cukup untuk OS + Docker images + data restore + PostgreSQL + temporary files.
- RAM cukup untuk seluruh service.

## 4.2 Login dan update Ubuntu

```bash
ssh <USER>@<IP_VPS_BARU>
```

Pastikan sesi SSH stabil.

```bash
sudo apt update
sudo apt upgrade -y
```

Install tool dasar:

```bash
sudo apt install -y curl ca-certificates gnupg lsb-release tar gzip rsync
```

`sha256sum` biasanya sudah tersedia melalui GNU coreutils pada Ubuntu. Verifikasi:

```bash
command -v sha256sum
```

## 4.3 Install Docker Engine dan Compose

Docker harus terpasang **sebelum restore**. Gunakan metode instalasi resmi Docker untuk Ubuntu.

Setelah instalasi:

```bash
sudo systemctl enable --now docker
sudo docker --version
sudo docker compose version
sudo docker info
```

Jangan lanjut jika Docker daemon atau `docker compose` belum berfungsi.

## 4.4 Siapkan user service

Backup service Render/TTS menggunakan:

```text
User=zkonten
Group=zkonten
```

Jika belum ada:

```bash
sudo id zkonten >/dev/null 2>&1 || sudo useradd -m -s /bin/bash zkonten
```

## 4.5 Siapkan direktori backup

```bash
sudo mkdir -p /opt/backup/vps
```

---

# 5. SALIN BACKUP KE VPS BARU

Salin **satu folder backup lengkap** dari PC/external storage ke VPS baru.

Contoh PowerShell Windows:

```powershell
scp -r .\vps-backup-2026-08-28-22.30-KELAPA zkonten@<IP_VPS_BARU>:/opt/backup/vps/
```

Jika upload ke home directory terlebih dahulu:

```bash
sudo mv ~/vps-backup-* /opt/backup/vps/
```

Verifikasi:

```bash
sudo ls -lah /opt/backup/vps/
sudo find /opt/backup/vps -mindepth 1 -maxdepth 1 -type d -name 'vps-backup-*' -printf '%f\n'
```

---

# 6. DOWNLOAD RESTORE SCRIPT

```bash
sudo curl -fsSL https://raw.githubusercontent.com/elisawa/Recovery-Kit-VPS-Ubuntu/main/scripts/restore-vps.sh -o /tmp/restore-vps.sh
sudo chmod 700 /tmp/restore-vps.sh
sudo bash -n /tmp/restore-vps.sh && echo "RESTORE SCRIPT OK"
```

---

# 7. WAJIB DRY-RUN

Misalnya:

```text
/opt/backup/vps/vps-backup-2026-08-28-22.30-KELAPA
```

Jalankan:

```bash
sudo /tmp/restore-vps.sh \
  --backup-dir /opt/backup/vps/vps-backup-2026-08-28-22.30-KELAPA \
  --dry-run
```

Dry-run harus menghasilkan:

```text
Backup structure: OK
Archives: OK
SHA-256: OK
Docker image digests: OK
DRY-RUN PASSED
```

**Jangan live restore jika dry-run gagal.**

Jika digest image `MISSING` atau `MISMATCH`, berhenti dan selesaikan masalah image terlebih dahulu.

---

# 8. CHECKLIST SEBELUM LIVE RESTORE

Semua item berikut harus terpenuhi:

### Host

- [ ] Ubuntu Server LTS sudah terinstall.
- [ ] VPS baru sudah dapat diakses melalui SSH.
- [ ] Sesi SSH stabil.
- [ ] User sudo/root tersedia.
- [ ] Docker Engine aktif.
- [ ] Docker Compose Plugin aktif.
- [ ] `tar` tersedia.
- [ ] `sha256sum` tersedia.
- [ ] `realpath` tersedia.
- [ ] `curl` tersedia.
- [ ] `systemctl` tersedia.
- [ ] User `zkonten` tersedia.
- [ ] RAM cukup.
- [ ] Disk kosong cukup.
- [ ] Internet aktif.

### Backup

- [ ] Backup berasal dari VPS yang dipercaya.
- [ ] Folder backup lengkap.
- [ ] `manifest/checksums.sha256` tersedia.
- [ ] SHA-256 pass.
- [ ] Archive readability pass.
- [ ] Docker image digest pass.
- [ ] Backup external tetap tersedia sebagai rollback source.

### Infrastruktur

- [ ] Akses provider VPS tersedia.
- [ ] Akses DNS/domain tersedia.
- [ ] Public IP baru diketahui.
- [ ] DNS/IP cutover sudah direncanakan.
- [ ] Credential/password yang dibutuhkan tersedia.
- [ ] Tidak ada perubahan penting yang hanya tersimpan di VPS lama.

### Keamanan restore

- [ ] Tidak ada live restore di production lama.
- [ ] Ada rollback plan.
- [ ] Jangan menutup sesi SSH sampai SSH pada VPS baru sudah diverifikasi.
- [ ] Jangan menghapus backup external.
- [ ] `--restore-system` belum digunakan kecuali memang diperlukan.

---

# 9. LIVE RESTORE

Setelah checklist lengkap:

```bash
sudo /tmp/restore-vps.sh \
  --backup-dir /opt/backup/vps/vps-backup-2026-08-28-22.30-KELAPA
```

Script meminta:

```text
Type YES to continue:
```

Ketik:

```text
YES
```

Live restore akan membuat safety snapshot, menghentikan container terdampak, menyiapkan Docker network, mengembalikan Compose/data/volume, PostgreSQL, Render/TTS, kemudian menyalakan service dan menjalankan health checks.

System configuration **tidak** dipulihkan kecuali `--restore-system` digunakan.

---

# 10. `--restore-system`

Default restore sengaja tidak memulihkan konfigurasi host.

`--restore-system` dapat memulihkan:

- Docker configuration
- UFW
- Fail2Ban
- cron
- systemd configuration

**SSH tetap tidak dipulihkan otomatis.**

Gunakan opsi ini hanya setelah konfigurasi host baru diperiksa dan potensi konflik dipahami.

---

# 11. VERIFIKASI SETELAH RESTORE

Jangan menganggap restore sukses hanya karena script selesai.

## Docker

```bash
sudo docker ps -a
```

Container utama yang diharapkan:

```text
postgres
n8n
npm
cloudbeaver
uptime-kuma
dockge
portainer
```

Jika sandbox digunakan, pastikan sandbox juga aktif.

## PostgreSQL

```bash
sudo docker exec postgres pg_isready -U admin -d postgres
sudo docker exec postgres psql -U admin -d postgres -c '\l'
sudo docker exec postgres psql -U n8n -d n8n_konten -c 'SELECT current_user, current_database();'
```

## n8n

```bash
curl -fsS http://127.0.0.1:5678/healthz
```

Kemudian buka domain HTTPS n8n dan verifikasi workflow, credential, execution history, dan test execution.

## Nginx Proxy Manager / SSL

Verifikasi NPM aktif, proxy host aktif, SSL certificate tersedia, dan HTTPS domain dapat dibuka dari internet.

## Render

```bash
sudo systemctl status render-service.service --no-pager
curl -fsS http://127.0.0.1:5006/health
```

## TTS

```bash
sudo systemctl status tts-service.service --no-pager
```

Pastikan endpoint TTS yang digunakan aplikasi dapat diakses.

## SSH

Pastikan SSH tetap dapat digunakan sebelum menutup sesi SSH yang digunakan untuk recovery.

---

# 12. SAFETY SNAPSHOT

Live restore membuat:

```text
/opt/recovery-before-restore/<timestamp>
```

Jangan hapus sampai n8n, PostgreSQL, NPM/SSL, Render, TTS, workflow production, SSH, dan DNS/domain semuanya sudah diverifikasi.

---

# 13. HASIL VALIDASI YANG SUDAH DILAKUKAN

Backup yang diuji sebelumnya:

```text
/opt/backup/vps/2026-08-28-123625
```

Hasil validasi:

- 54 file berhasil diverifikasi SHA-256.
- Semua Docker archive dapat dibaca.
- `n8n_konten.dump` berhasil direstore ke database test bersih.
- Database test berisi 126 tabel.
- 20 workflow.
- 2 credential.
- 174 execution.
- n8n filesystem archive berhasil diekstrak.
- `data/config` tersedia.
- n8n storage sekitar 317.60 MB pada test.
- Render Service archive berhasil diekstrak.
- TTS Service archive berhasil diekstrak.
- Python 3.14.4 virtual environment Render/TTS dapat dieksekusi pada test.
- Docker image digests cocok dengan manifest backup.

**Catatan:** pengujian tersebut memvalidasi backup dan komponen recovery. Itu belum sama dengan full disaster-recovery test pada VPS baru yang benar-benar terpisah.

---

# 14. QUICK COMMANDS

### Backup

```bash
sudo backup-vps
```

### Backup help

```bash
sudo backup-vps --help
```

### List backup

```bash
sudo find /opt/backup/vps -mindepth 1 -maxdepth 1 -type d -name 'vps-backup-*' -printf '%f\n' | sort -r
```

### Download restore script

```bash
sudo curl -fsSL https://raw.githubusercontent.com/elisawa/Recovery-Kit-VPS-Ubuntu/main/scripts/restore-vps.sh -o /tmp/restore-vps.sh
sudo chmod 700 /tmp/restore-vps.sh
```

### Restore dry-run

```bash
sudo /tmp/restore-vps.sh \
  --backup-dir /opt/backup/vps/<NAMA-BACKUP> \
  --dry-run
```

### Live restore

```bash
sudo /tmp/restore-vps.sh \
  --backup-dir /opt/backup/vps/<NAMA-BACKUP>
```

---

# 15. Recovery flow

```text
HEALTHY VPS
    ↓
BACKUP
    ↓
VERIFY SHA-256 / ARCHIVES / IMAGE DIGEST
    ↓
COPY BACKUP OUTSIDE VPS
    ↓
FRESH UBUNTU SERVER LTS
    ↓
SSH + SUDO
    ↓
INSTALL DOCKER + COMPOSE
    ↓
CREATE REQUIRED HOST USER
    ↓
COPY VERIFIED BACKUP
    ↓
DOWNLOAD RESTORE SCRIPT
    ↓
DRY-RUN
    ↓
CHECKLIST
    ↓
LIVE RESTORE
    ↓
HEALTH CHECK
    ↓
APPLICATION TEST
    ↓
DNS / PRODUCTION CUTOVER
```

**Jangan melewati dry-run dan jangan menghapus backup external sebelum VPS hasil restore terbukti sehat.**

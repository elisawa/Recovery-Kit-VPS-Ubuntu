# Recovery Kit VPS Ubuntu

Recovery scripts for rebuilding the VPS from a verified backup.

## Verified restore workflow

Use `scripts/backup-vps.sh` to create a backup and `scripts/restore-vps.sh` to validate or restore it.

### Safety rules

- Always run `restore-vps.sh --dry-run` first.
- Never restore SSH configuration automatically.
- Keep the recovery backup outside the VPS as well as on the VPS.
- A live restore modifies Docker data, PostgreSQL, systemd services, and application files. Do not test live restore on production unless a rollback plan is prepared.

### Current restore script

`restore-vps.sh` V9 validates:

- backup structure
- archive readability
- SHA-256 checksums
- Docker image repository/tag/digest

The live restore path also creates a pre-restore safety snapshot under `/opt/recovery-before-restore/<timestamp>` and stops affected services before replacing application data.

### Recovery checklist

1. Provision a fresh Ubuntu VPS.
2. Install and start Docker and Docker Compose.
3. Copy the verified backup directory to the new VPS.
4. Download `scripts/restore-vps.sh` from this repository.
5. Run the dry-run against the backup.
6. Confirm all required files, archives, checksums, and image digests pass.
7. Run the live restore interactively and type `YES` after reviewing the warning.
8. Verify PostgreSQL, n8n, NPM/SSL, Render, TTS, and SSH access.
9. Keep the pre-restore safety snapshot until the recovered VPS is confirmed healthy.

## Tested backup

The backup used during validation was `/opt/backup/vps/2026-08-28-123625`.

Validation performed:

- 54 backup files verified by SHA-256.
- Docker archives were readable.
- PostgreSQL `n8n_konten.dump` was restored successfully into a clean test database.
- Restored test database contained 126 tables, 20 workflows, 2 credentials, and 174 executions.
- n8n filesystem archive restored successfully, including `data/config` and 317.60 MB of storage data.
- Render and TTS archives restored successfully into temporary test directories and their Python 3.14.4 virtual environments executed correctly.
- Docker image digests matched the recorded backup manifest on the validation VPS.

These tests validate the backup contents and recovery components. They are not a substitute for a full disaster-recovery test on a separate fresh VPS.
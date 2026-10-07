# VPS Backup Manager

A resilient, multi-site automated backup manager for Linux VPS environments. It handles PostgreSQL database dumps, integrity verification, Cloudflare R2 media sync, local asset folder/CDN synchronization or archiving, automated log rotation, modern public HTML status dashboards for Caddy/Nginx, and dual notifications via Discord and Telegram.

---

## Key Features

- **Per-Site Rclone Remotes**: Every site can define its own dedicated Google Drive, Nextcloud, or R2 remotes (`SITE<N>_REMOTE_*`), completely isolating credentials and destination buckets across projects.
- **Granular Remote Retention**: Configure a general retention period (`SITE<N>_DB_REMOTE_RETENTION_DAYS`) or dedicated per-provider days (`SITE<N>_DB_REMOTE_RETENTION_DAYS_GDRIVE`, `SITE<N>_DB_REMOTE_RETENTION_DAYS_NEXTCLOUD`).
- **Optional Versioned Trash for Folders & CDN**: When syncing local asset folders, versioned date-stamped trash bins (`SITE<N>_FOLDER_TRASH_PATH_*`) are completely optional. If omitted, standard direct synchronization is performed.
- **Multi-Site Discovery**: Automatically scans and processes any number of sites configured as `SITE<N>_*` in `.env` without modifying code.
- **Local Folders & CDN Backups**: Supports backing up local asset directories (e.g. CDN folders, uploads) using either high-performance incremental sync with dated trash (`rclone sync --backup-dir`) or compressed versioned archives (`tar.gz` or `zip`).
- **PostgreSQL Dumps & Verification**: Generates custom compressed PostgreSQL dumps (`.dump`) and verifies archive integrity using `pg_restore --list` before starting uploads.
- **Credential Protection**: Database passwords are automatically parsed from connection URIs and supplied via `PGPASSWORD` at runtime, preventing plain-text password exposure in `ps aux` or `/proc/<pid>/cmdline`.
- **Cloudflare R2 Anti-Wipe Protection**: Checks bucket size and file counts before performing `rclone sync`. If the source bucket is empty or unreachable, the sync aborts immediately to prevent wiping remote backups.
- **Versioned Trash Retention (`--backup-dir`)**: Preserves overwritten or deleted files in dated trash folders before pruning them according to retention policies.
- **Automated Log Rotation**: Prevents log files from consuming VPS disk space by automatically truncating older entries when exceeding configurable size thresholds (`BACKUP_LOG_MAX_MB`).
- **Live HTML Status Dashboard**: Generates a self-contained, responsive dark-mode HTML dashboard (`generate_report.py`) with real-time log search and system health indicators, ready to be served publicly in read-only mode by Caddy or Nginx.
- **Dual Alerts (Discord & Telegram)**: Delivers rich embed status reports to Discord channels and instant alerts + full log document delivery to Telegram bots.
- **Concurrency Lock (`flock`)**: Prevents overlapping backup cron executions using Linux file descriptors.

---

## Requirements

Ensure the following tools are installed on your Linux system:

| Tool | Purpose |
| :--- | :--- |
| `bash` (>= 4.4) | Script execution with `set -Eeuo pipefail` |
| `rclone` | Cloud storage sync and copy operations |
| `pg_dump` & `pg_restore` | PostgreSQL database dumping and integrity checks |
| `python3` (>= 3.8) | HTML status dashboard rendering |
| `curl` | Discord and Telegram webhook delivery |
| `jq` | Building JSON payloads for Discord embeds |
| `flock` | Concurrency locking |
| `find` | Local dump cleanup and retention management |
| `tar` & `gzip` | Standard Unix compression for folder archive mode |
| `zip` | Optional zip compression for folder archive mode |

On Debian/Ubuntu, install the core dependencies via:
```bash
sudo apt-get update
sudo apt-get install -y postgresql-client rclone curl jq util-linux python3 tar zip
```

---

## Directory Structure

```text
backup_manager/
├── run_backup.sh        # Main backup orchestrator script
├── generate_report.py   # Self-contained HTML status dashboard generator
├── .env.example         # Environment configuration template
├── .env                 # Private configuration file (git-ignored)
└── logs/
    ├── backup.log       # System log file (auto-rotated)
    └── index.html       # Public read-only dashboard served by Caddy
```

---

## Configuration (`.env`)

Copy the configuration template:
```bash
cp .env.example .env
chmod 600 .env
chmod +x run_backup.sh generate_report.py
```

### 1. General & Dashboard Settings

```env
BACKUP_LOG_FILE="/home/felt/backup_manager/logs/backup.log"
BACKUP_LOG_MAX_MB=10
BACKUP_HTML_FILE="/home/felt/backup_manager/logs/index.html"

# Telegram Notifications
TELEGRAM_BOT_TOKEN="your_bot_token_here"
TELEGRAM_CHAT_ID="your_chat_id_here"
TELEGRAM_SEND_LOG_DOCUMENT=true
```

### 2. Defining Sites (`SITE1`, `SITE2`, `SITE3`, ...)

Sites are declared dynamically with numerical suffixes (`SITE1`, `SITE2`, etc.):

```env
# Site 1: Production Database + Cloudflare R2
SITE1_ENABLE=true
SITE1_NAME="production_site"
SITE1_DB_URL="postgres://user:password@127.0.0.1:5432/production_db"
SITE1_REMOTE_GDRIVE="production_gdrive"
SITE1_REMOTE_NEXTCLOUD="nextcloud"
SITE1_REMOTE_R2="production_r2"
SITE1_DB_LOCAL_DIR="/home/felt/backup_manager/dumps/production_site"
SITE1_DB_PATH_GDRIVE="backups/production/database"
SITE1_DB_PATH_NEXTCLOUD="backups/production/database"
SITE1_R2_ENABLE=true
SITE1_R2_BUCKET="production-bucket"
SITE1_R2_PATH_GDRIVE="backups/production/r2"
SITE1_R2_TRASH_PATH_GDRIVE="backups/production/r2_trash"
SITE1_DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."

# Site 2: Database + Local CDN / Assets Folder
SITE2_ENABLE=true
SITE2_NAME="assets_site"
SITE2_DB_URL="postgres://user:password@127.0.0.1:5432/assets_db"
SITE2_REMOTE_GDRIVE="assets_drive"
SITE2_REMOTE_NEXTCLOUD="nextcloud"
SITE2_DB_LOCAL_DIR="/home/felt/backup_manager/dumps/assets_site"
SITE2_DB_PATH_GDRIVE="backups/assets/database"
SITE2_DB_PATH_NEXTCLOUD="backups/assets/database"
SITE2_FOLDER_ENABLE=true
SITE2_FOLDER_SRC="/var/www/assets_site/cdn"
SITE2_FOLDER_PATH_GDRIVE="backups/assets/cdn"
SITE2_FOLDER_PATH_NEXTCLOUD="backups/assets/cdn"
SITE2_FOLDER_MODE="sync" # "sync" for incremental mirror or "archive" for tar.gz/zip
SITE2_FOLDER_TRASH_PATH_GDRIVE="backups/assets/cdn_trash"
SITE2_DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

---

## Serving the Public Status Page with Caddy

To publish the read-only status dashboard publicly, add a simple virtual host to your `Caddyfile`:

```caddyfile
status.yourdomain.com {
    root * /home/felt/backup_manager/logs
    file_server
}
```

Then reload Caddy:
```bash
sudo systemctl reload caddy
```

---

## Running the Backup

Manual execution:
```bash
./run_backup.sh
```

Scheduled execution via `crontab`:
```bash
crontab -e
```
Add a daily schedule (e.g. every night at 03:00 AM):
```text
0 3 * * * /home/felt/backup_manager/run_backup.sh >/dev/null 2>&1
```

---

## License

MIT License. Free for personal and commercial use.

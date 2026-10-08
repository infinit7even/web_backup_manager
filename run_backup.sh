#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# VPS BACKUP MANAGER
#
# Features:
#   - PostgreSQL custom compressed dumps with verification (pg_restore --list)
#   - Per-site isolated rclone remotes (Google Drive, Nextcloud, R2, etc.)
#   - Cloudflare R2 / S3 media synchronization with anti-wipe safety checks
#   - Local folders / CDN incremental sync or compressed archives (tar.gz / zip)
#   - Versioned trash retention using rclone --backup-dir
#   - Automated log file size rotation to prevent disk exhaustion
#   - Modern responsive HTML status dashboard for public read-only serving (Caddy)
#   - Concurrency locking with flock
#   - Discord Webhook embeds & Telegram Bot alerts with log document delivery
#
# Configuration:
#   ./run_backup.sh
#   └── .env
###############################################################################

###############################################################################
# BASE CONFIGURATION
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Automatic .env alignment & formatting utility
if [[ "${1:-}" == "--align-env" || "${1:-}" == "--format-env" || "${1:-}" == "-a" ]]; then
    if [[ -f "${SCRIPT_DIR}/align_env.py" ]]; then
        exec python3 "${SCRIPT_DIR}/align_env.py" "$ENV_FILE" "${SCRIPT_DIR}/.env.example"
    else
        echo "ERROR: align_env.py helper not found in ${SCRIPT_DIR}" >&2
        exit 1
    fi
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Configuration file not found: $ENV_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

BACKUP_LOG_FILE="${BACKUP_LOG_FILE:-${SCRIPT_DIR}/logs/backup.log}"
BACKUP_LOG_MAX_MB="${BACKUP_LOG_MAX_MB:-10}"
BACKUP_HTML_FILE="${BACKUP_HTML_FILE:-${SCRIPT_DIR}/logs/index.html}"
LOCK_FILE="${LOCK_FILE:-/tmp/backup-manager.lock}"
SITES_STATUS_JSON="/tmp/backup_sites_status.json"

REMOTE_GDRIVE="${REMOTE_GDRIVE:-}"
REMOTE_NEXTCLOUD="${REMOTE_NEXTCLOUD:-}"
REMOTE_R2="${REMOTE_R2:-}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_SEND_LOG_DOCUMENT="${TELEGRAM_SEND_LOG_DOCUMENT:-true}"

mkdir -p "$(dirname "$BACKUP_LOG_FILE")"

###############################################################################
# LOCK (CONCURRENCY PROTECTION)
###############################################################################

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "ERROR: Another instance of backup manager is already running." >&2
    exit 2
fi

###############################################################################
# LOG ROTATION
###############################################################################

rotate_log_if_needed() {
    local max_bytes=$(( ${BACKUP_LOG_MAX_MB:-10} * 1024 * 1024 ))
    [[ ! -f "$BACKUP_LOG_FILE" ]] && return 0

    local current_size
    current_size="$(wc -c < "$BACKUP_LOG_FILE" 2>/dev/null || echo 0)"

    if (( current_size > max_bytes )); then
        log "Log rotation: current size (${current_size} bytes) exceeds limit of ${BACKUP_LOG_MAX_MB}MB. Retaining last 5000 lines."
        local tmp_log="${BACKUP_LOG_FILE}.tmp"
        tail -n 5000 "$BACKUP_LOG_FILE" > "$tmp_log" 2>/dev/null && mv "$tmp_log" "$BACKUP_LOG_FILE"
    fi
}

###############################################################################
# TELEGRAM NOTIFICATIONS
###############################################################################

notify_telegram() {
    local bot_token="${1:-$TELEGRAM_BOT_TOKEN}"
    local chat_id="${2:-$TELEGRAM_CHAT_ID}"
    local message="${3:-}"

    [[ -z "$bot_token" || -z "$chat_id" || -z "$message" ]] && return 0

    curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${message}" \
        -d "parse_mode=HTML" \
        --max-time 15 >/dev/null 2>&1 || log "WARNING: Failed to dispatch Telegram notification."
}

send_telegram_document() {
    local bot_token="${1:-$TELEGRAM_BOT_TOKEN}"
    local chat_id="${2:-$TELEGRAM_CHAT_ID}"
    local file_path="${3:-}"
    local caption="${4:-Backup Session Log}"

    [[ -z "$bot_token" || -z "$chat_id" || -z "$file_path" || ! -f "$file_path" ]] && return 0

    curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendDocument" \
        -F "chat_id=${chat_id}" \
        -F "document=@${file_path}" \
        -F "caption=${caption}" \
        --max-time 30 >/dev/null 2>&1 || log "WARNING: Failed to send Telegram document."
}

###############################################################################
# GLOBAL STATE
###############################################################################

TOTAL_SITES=0
SUCCESS_SITES=0
FAILED_SITES=0
PARTIAL_SITES=0

CURRENT_SITE=""
CURRENT_OPERATION=""

###############################################################################
# LOGGING
###############################################################################

log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    printf '[%s] %s\n' "$timestamp" "$*" | tee -a "$BACKUP_LOG_FILE" 2>/dev/null || printf '[%s] %s\n' "$timestamp" "$*" >&2 || true
}

###############################################################################
# ERROR HANDLER
###############################################################################

on_error() {
    local exit_code=$?
    local line_no="${1:-unknown}"

    log "UNEXPECTED ERROR: site=${CURRENT_SITE:-N/A} operation=${CURRENT_OPERATION:-N/A} line=${line_no} exit=${exit_code}"

    return "$exit_code"
}

trap 'on_error $LINENO' ERR

###############################################################################
# DEPENDENCIES
###############################################################################

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $cmd"
        return 1
    fi
}

check_dependencies() {
    local failed=0

    for cmd in \
        rclone \
        pg_dump \
        pg_restore \
        curl \
        find \
        flock \
        tar
    do
        if ! require_command "$cmd"; then
            failed=1
        fi
    done

    if ! command -v jq >/dev/null 2>&1; then
        log "ERROR: jq is not installed. It is required for Discord embed generation."
        failed=1
    fi

    return "$failed"
}

###############################################################################
# DISCORD NOTIFICATIONS
###############################################################################

notify_discord() {
    local webhook_url="${1:-}"
    local title="${2:-Backup Manager}"
    local description="${3:-}"
    local color="${4:-15158332}"

    [[ -z "$webhook_url" ]] && return 0

    local payload

    payload="$(
        jq -n \
            --arg title "$title" \
            --arg description "$description" \
            --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            --argjson color "$color" \
            '{
                embeds: [{
                    title: $title,
                    description: $description,
                    color: $color,
                    footer: {
                        text: "VPS Backup Manager"
                    },
                    timestamp: $timestamp
                }]
            }'
    )"

    if ! curl \
        --silent \
        --show-error \
        --fail \
        --max-time 15 \
        --output /dev/null \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$webhook_url"
    then
        log "WARNING: Unable to dispatch Discord notification."
    fi
}

###############################################################################
# RCLONE TARGET FORMATTER
###############################################################################

format_target() {
    local remote="$1"
    local path="${2:-}"

    [[ -z "$path" ]] && return 0

    if [[ "$path" == *:* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s:%s\n' "$remote" "$path"
    fi
}

###############################################################################
# RCLONE HEALTH CHECK
###############################################################################

check_rclone_target() {
    local target="$1"

    [[ -z "$target" ]] && return 0

    CURRENT_OPERATION="check rclone target"

    if ! rclone lsd "$target" >/dev/null 2>&1; then
        log "ERROR: rclone target unreachable: $target"
        return 1
    fi
}

###############################################################################
# DATABASE BACKUP (POSTGRESQL)
###############################################################################

backup_site_db() {
    local name="$1"
    local db_url="$2"
    local local_dir="$3"
    local remote_retention_gdrive="$4"
    local remote_retention_nc="$5"
    local dest_gdrive="$6"
    local dest_nextcloud="$7"
    local webhook="$8"

    CURRENT_OPERATION="database backup"

    log "--- [DB] Starting database backup: $name ---"

    if [[ -z "$db_url" ]]; then
        log "ERROR: DB_URL not configured for $name"
        notify_discord \
            "$webhook" \
            "❌ Missing DB Configuration" \
            "PostgreSQL connection URL not set for **$name**." \
            15158332
        return 1
    fi

    if [[ -z "$local_dir" ]]; then
        log "ERROR: Local DB directory not configured for $name"
        notify_discord \
            "$webhook" \
            "❌ Missing DB Configuration" \
            "Local backup directory not set for **$name**." \
            15158332
        return 1
    fi

    if ! mkdir -p "$local_dir"; then
        log "ERROR: Failed to create local directory: $local_dir"
        notify_discord \
            "$webhook" \
            "❌ Directory Creation Failed" \
            "Cannot create local directory \`$local_dir\` for **$name**." \
            15158332
        return 1
    fi

    local timestamp
    timestamp="$(date '+%Y_%m_%d_%H_%M_%S')"

    local dump_filename
    dump_filename="${name}_db_${timestamp}.dump"

    local dump_file
    dump_file="${local_dir}/${dump_filename}"

    log "Creating PostgreSQL dump..."

    local clean_db_url="$db_url"
    local pg_pass=""

    # Extract password to avoid exposing it in process listings (ps aux)
    if [[ "$db_url" =~ ^([a-zA-Z0-9+.-]+://)([^:]+):(.*)@(.*)$ ]]; then
        local proto="${BASH_REMATCH[1]}"
        local user="${BASH_REMATCH[2]}"
        local raw_pass="${BASH_REMATCH[3]}"
        local rest="${BASH_REMATCH[4]}"
        clean_db_url="${proto}${user}@${rest}"
        printf -v pg_pass '%b' "${raw_pass//%/\\x}"
    elif [[ "$db_url" =~ password=([^[:space:]]+) ]]; then
        pg_pass="${BASH_REMATCH[1]}"
        clean_db_url="${db_url//password=${pg_pass}/}"
    fi

    if ! PGPASSWORD="${pg_pass:-${PGPASSWORD:-}}" pg_dump \
        "$clean_db_url" \
        --format=custom \
        --file="$dump_file"
    then
        log "ERROR: pg_dump failed for $name"
        rm -f "$dump_file"

        notify_discord \
            "$webhook" \
            "❌ Database Backup Failed" \
            "pg_dump returned an error for **$name**." \
            15158332

        return 1
    fi

    log "Verifying dump integrity..."

    if ! pg_restore \
        --list \
        "$dump_file" >/dev/null 2>&1
    then
        log "ERROR: Corrupt or invalid dump file: $dump_file"
        rm -f "$dump_file"

        notify_discord \
            "$webhook" \
            "❌ Invalid Database Dump" \
            "Dump integrity verification failed for **$name**." \
            15158332

        return 1
    fi

    local dump_size
    dump_size="$(du -h "$dump_file" | cut -f1)"

    log "Dump created: $dump_filename ($dump_size)"

    local uploaded_count=0
    local failed_count=0

    # GOOGLE DRIVE UPLOAD
    if [[ -n "$dest_gdrive" ]]; then
        log "Uploading DB -> Google Drive: $dest_gdrive"

        if rclone copyto \
            "$dump_file" \
            "${dest_gdrive}/${dump_filename}" \
            --stats=30s
        then
            ((uploaded_count+=1))

            if [[ -n "$remote_retention_gdrive" ]]; then
                log "Google Drive retention: ${remote_retention_gdrive} days"

                if ! rclone delete \
                    "$dest_gdrive" \
                    --include "*.dump" \
                    --min-age "${remote_retention_gdrive}d"
                then
                    log "WARNING: Google Drive retention cleanup encountered an issue."
                fi
            fi
        else
            ((failed_count+=1))
            log "ERROR: Database upload to Google Drive failed."
        fi
    fi

    # NEXTCLOUD UPLOAD
    if [[ -n "$dest_nextcloud" ]]; then
        log "Uploading DB -> Nextcloud: $dest_nextcloud"

        if rclone copyto \
            "$dump_file" \
            "${dest_nextcloud}/${dump_filename}" \
            --stats=30s
        then
            ((uploaded_count+=1))

            if [[ -n "$remote_retention_nc" ]]; then
                log "Nextcloud retention: ${remote_retention_nc} days"

                if ! rclone delete \
                    "$dest_nextcloud" \
                    --include "*.dump" \
                    --min-age "${remote_retention_nc}d"
                then
                    log "WARNING: Nextcloud retention cleanup encountered an issue."
                fi
            fi
        else
            ((failed_count+=1))
            log "ERROR: Database upload to Nextcloud failed."
        fi
    fi

    # EVALUATION
    if (( uploaded_count == 0 )); then
        log "ERROR: No remote destination completed the upload."

        notify_discord \
            "$webhook" \
            "❌ Database Not Saved" \
            "**Site:** \`$name\`\n**Dump:** \`$dump_filename\`\n**Size:** \`$dump_size\`\n\nNo remote destination completed the upload." \
            15158332

        return 1
    fi

    if (( failed_count > 0 )); then
        log "WARNING: Database backup partially succeeded for $name."

        notify_discord \
            "$webhook" \
            "⚠️ Database Partially Saved" \
            "**Site:** \`$name\`\n**Dump:** \`$dump_filename\`\n**Size:** \`$dump_size\`\n\nAt least one remote destination failed." \
            16776960

        return 2
    fi

    log "Database backup completed: $name"

    notify_discord \
        "$webhook" \
        "💾 Database Saved" \
        "**Site:** \`$name\`\n**Dump:** \`$dump_filename\`\n**Size:** \`$dump_size\`\n**Retention:** \`${remote_retention} days\`" \
        3066993

    return 0
}

###############################################################################
# R2 - BUCKET STATS & CIRCUIT BREAKER
###############################################################################

get_r2_stats() {
    local r2_src="$1"
    local json

    if ! json="$(rclone size "$r2_src" --json --fast-list 2>/dev/null)"; then
        log "ERROR: Failed to query R2 bucket: $r2_src"
        return 1
    fi

    if ! jq -e . >/dev/null 2>&1 <<<"$json"; then
        log "ERROR: Invalid JSON response from R2."
        return 1
    fi

    R2_COUNT="$(jq -r '.count // 0' <<<"$json")"
    R2_BYTES="$(jq -r '.bytes // 0' <<<"$json")"

    if ! [[ "$R2_COUNT" =~ ^[0-9]+$ ]]; then
        log "ERROR: Invalid R2 object count: $R2_COUNT"
        return 1
    fi

    if ! [[ "$R2_BYTES" =~ ^[0-9]+$ ]]; then
        log "ERROR: Invalid R2 size: $R2_BYTES"
        return 1
    fi

    R2_MB=$((R2_BYTES / 1024 / 1024))
    return 0
}

###############################################################################
# R2 -> DESTINATION SYNC
###############################################################################

sync_r2_destination() {
    local name="$1"
    local r2_src="$2"
    local destination="$3"
    local trash_base="$4"
    local trash_retention="$5"
    local destination_name="$6"
    local webhook="$7"

    [[ -z "$destination" ]] && return 0

    local today
    today="$(date '+%Y-%m-%d')"

    local trash
    trash="${trash_base:-${destination}_trash}/${today}"

    log "--- [R2] $name -> $destination_name ---"
    log "Source: $r2_src"
    log "Destination: $destination"
    log "Backup-dir: $trash"

    if rclone sync \
        "$r2_src" \
        "$destination" \
        --backup-dir "$trash" \
        --fast-list \
        --transfers 4 \
        --checkers 8 \
        --stats=30s
    then
        log "Sync R2 -> $destination_name completed."

        if [[ -n "$trash_retention" && -n "$trash_base" ]]; then
            log "Pruning trash folder: ${trash_retention} days"

            if ! rclone delete \
                "$trash_base" \
                --min-age "${trash_retention}d" \
                --rmdirs
            then
                log "WARNING: Trash cleanup failed for $destination_name."
            fi
        fi

        notify_discord \
            "$webhook" \
            "☁️ Sync R2 → $destination_name" \
            "**Site:** \`$name\`\n**R2:** \`$R2_COUNT files (~${R2_MB} MB)\`\n**Destination:** \`$destination\`\n**Trash:** \`$trash\`" \
            3066993

        return 0
    fi

    log "ERROR: Sync R2 -> $destination_name failed."

    notify_discord \
        "$webhook" \
        "❌ Sync R2 → $destination_name Failed" \
        "Media synchronization for **$name** returned an error." \
        15158332

    return 1
}

###############################################################################
# R2 MEDIA BACKUP
###############################################################################

backup_site_r2() {
    local name="$1"
    local r2_src="$2"
    local gdrive_dst="$3"
    local nextcloud_dst="$4"
    local gdrive_trash_base="$5"
    local nextcloud_trash_base="$6"
    local trash_retention="$7"
    local webhook="$8"

    CURRENT_OPERATION="R2 media backup"

    if [[ -z "$r2_src" ]]; then
        log "WARNING: R2 source not configured for $name."
        return 0
    fi

    log "Checking R2 bucket: $r2_src"

    if ! get_r2_stats "$r2_src"; then
        notify_discord \
            "$webhook" \
            "🚨 R2 Unreachable" \
            "Cannot query R2 bucket for **$name**.\n\nSynchronization **BLOCKED** for safety." \
            15158332
        return 1
    fi

    log "R2: $R2_COUNT files (~${R2_MB} MB)"

    # Empty bucket safety tripwire
    if (( R2_COUNT == 0 )); then
        log "SAFETY TRIPWIRE: R2 bucket is EMPTY: $r2_src"

        notify_discord \
            "$webhook" \
            "🚨 R2 CIRCUIT BREAKER TRIGGERED" \
            "The R2 bucket for **$name** is **EMPTY**.\n\nSync aborted to prevent mass-deletion of remote backups." \
            15158332

        return 1
    fi

    local failed=0

    if [[ -n "$gdrive_dst" ]]; then
        if ! sync_r2_destination \
            "$name" \
            "$r2_src" \
            "$gdrive_dst" \
            "$gdrive_trash_base" \
            "$trash_retention" \
            "Google Drive" \
            "$webhook"
        then
            failed=1
        fi
    fi

    if [[ -n "$nextcloud_dst" ]]; then
        if ! sync_r2_destination \
            "$name" \
            "$r2_src" \
            "$nextcloud_dst" \
            "$nextcloud_trash_base" \
            "$trash_retention" \
            "Nextcloud" \
            "$webhook"
        then
            failed=1
        fi
    fi

    if (( failed != 0 )); then
        return 1
    fi

    return 0
}

###############################################################################
# LOCAL FOLDERS & CDN BACKUP
###############################################################################

backup_site_folder() {
    local name="$1"
    local folder_src="$2"
    local mode="$3"              # "sync" (default) or "archive"
    local archive_format="$4"    # "tar.gz" (default), "tar", "zip"
    local local_archive_dir="$5"
    local archive_retention="$6"
    local gdrive_dst="$7"
    local nextcloud_dst="$8"
    local gdrive_trash_base="$9"
    local nextcloud_trash_base="${10}"
    local trash_retention="${11}"
    local webhook="${12}"

    CURRENT_OPERATION="folder backup"

    if [[ -z "$folder_src" ]]; then
        log "WARNING: Folder source not specified for $name."
        return 0
    fi

    if [[ ! -d "$folder_src" ]]; then
        log "ERROR: Source folder not found or not a directory: $folder_src"
        notify_discord \
            "$webhook" \
            "❌ Source Folder Not Found" \
            "Directory \`$folder_src\` for **$name** does not exist." \
            15158332
        return 1
    fi

    local file_count
    file_count="$(find "$folder_src" -type f | wc -l)"
    local folder_size
    folder_size="$(du -sh "$folder_src" 2>/dev/null | cut -f1)"

    log "--- [FOLDER] Starting folder backup: $name ($folder_src) ---"
    log "Files found: $file_count ($folder_size)"

    if (( file_count == 0 )); then
        log "ALERT: Source folder is empty: $folder_src"
        notify_discord \
            "$webhook" \
            "⚠️ Empty Folder" \
            "Folder \`$folder_src\` for **$name** is empty. Operation skipped for safety." \
            16776960
        return 0
    fi

    local failed=0

    if [[ "$mode" == "archive" || "$mode" == "tar" || "$mode" == "tar.gz" || "$mode" == "zip" ]]; then
        local format="${archive_format:-tar.gz}"
        if [[ "$mode" == "tar" || "$mode" == "tar.gz" || "$mode" == "zip" ]]; then
            format="$mode"
        fi

        local ext="tar.gz"
        [[ "$format" == "zip" ]] && ext="zip"
        [[ "$format" == "tar" ]] && ext="tar"

        local archive_local_dir="${local_archive_dir:-${SCRIPT_DIR}/dumps/${name}_folder}"
        mkdir -p "$archive_local_dir"

        local timestamp
        timestamp="$(date '+%Y_%m_%d_%H_%M_%S')"
        local archive_filename="${name}_folder_${timestamp}.${ext}"
        local archive_file="${archive_local_dir}/${archive_filename}"

        log "Creating compressed archive ($format): $archive_filename..."

        local src_parent
        src_parent="$(dirname "$folder_src")"
        local src_base
        src_base="$(basename "$folder_src")"

        if [[ "$format" == "zip" ]]; then
            if ! (cd "$src_parent" && zip -rq "$archive_file" "$src_base"); then
                log "ERROR: Failed to create zip archive for $folder_src"
                rm -f "$archive_file"
                return 1
            fi
        elif [[ "$format" == "tar" ]]; then
            if ! tar -cf "$archive_file" -C "$src_parent" "$src_base"; then
                log "ERROR: Failed to create tar archive for $folder_src"
                rm -f "$archive_file"
                return 1
            fi
        else
            if ! tar -czf "$archive_file" -C "$src_parent" "$src_base"; then
                log "ERROR: Failed to create tar.gz archive for $folder_src"
                rm -f "$archive_file"
                return 1
            fi
        fi

        local archive_size
        archive_size="$(du -h "$archive_file" | cut -f1)"
        log "Archive created: $archive_filename ($archive_size)"

        if [[ -n "$gdrive_dst" ]]; then
            log "Uploading archive -> Google Drive: $gdrive_dst"
            if rclone copyto "$archive_file" "${gdrive_dst}/${archive_filename}" --stats=30s; then
                if [[ -n "$archive_retention" ]]; then
                    rclone delete "$gdrive_dst" --include "*.${ext}" --min-age "${archive_retention}d" || true
                fi
            else
                failed=1
                log "ERROR: Archive upload to Google Drive failed."
            fi
        fi

        if [[ -n "$nextcloud_dst" ]]; then
            log "Uploading archive -> Nextcloud: $nextcloud_dst"
            if rclone copyto "$archive_file" "${nextcloud_dst}/${archive_filename}" --stats=30s; then
                if [[ -n "$archive_retention" ]]; then
                    rclone delete "$nextcloud_dst" --include "*.${ext}" --min-age "${archive_retention}d" || true
                fi
            else
                failed=1
                log "ERROR: Archive upload to Nextcloud failed."
            fi
        fi

        if [[ -n "$archive_retention" ]]; then
            find "$archive_local_dir" -type f -name "*.${ext}" -mtime "+${archive_retention}" -delete 2>/dev/null || true
        fi

        if (( failed != 0 )); then
            notify_discord "$webhook" "❌ Archive Backup Failed" "Failed to upload archive to remote storage for **$name**." 15158332
            return 1
        fi

        notify_discord \
            "$webhook" \
            "📦 Folder Archived" \
            "**Site:** \`$name\`\n**Archive:** \`$archive_filename\`\n**Size:** \`$archive_size\`\n**Format:** \`$format\`" \
            3066993
        return 0

    else
        local today
        today="$(date '+%Y-%m-%d')"

        if [[ -n "$gdrive_dst" ]]; then
            local gdrive_trash="${gdrive_trash_base:-${gdrive_dst}_trash}/${today}"
            log "Sync Folder -> Google Drive: $folder_src -> $gdrive_dst"
            if rclone sync "$folder_src" "$gdrive_dst" --backup-dir "$gdrive_trash" --fast-list --transfers 4 --checkers 8 --stats=30s; then
                if [[ -n "$trash_retention" && -n "$gdrive_trash_base" ]]; then
                    rclone delete "$gdrive_trash_base" --min-age "${trash_retention}d" --rmdirs || true
                fi
                notify_discord "$webhook" "📁 Sync Folder → Google Drive" "**Site:** \`$name\`\n**Files:** \`$file_count (~$folder_size)\`\n**Destination:** \`$gdrive_dst\`\n**Trash:** \`$gdrive_trash\`" 3066993
            else
                failed=1
                log "ERROR: Folder sync to Google Drive failed."
            fi
        fi

        if [[ -n "$nextcloud_dst" ]]; then
            local nc_trash="${nextcloud_trash_base:-${nextcloud_dst}_trash}/${today}"
            log "Sync Folder -> Nextcloud: $folder_src -> $nextcloud_dst"
            if rclone sync "$folder_src" "$nextcloud_dst" --backup-dir "$nc_trash" --fast-list --transfers 4 --checkers 8 --stats=30s; then
                if [[ -n "$trash_retention" && -n "$nextcloud_trash_base" ]]; then
                    rclone delete "$nextcloud_trash_base" --min-age "${trash_retention}d" --rmdirs || true
                fi
                notify_discord "$webhook" "📁 Sync Folder → Nextcloud" "**Site:** \`$name\`\n**Files:** \`$file_count (~$folder_size)\`\n**Destination:** \`$nextcloud_dst\`\n**Trash:** \`$nc_trash\`" 3066993
            else
                failed=1
                log "ERROR: Folder sync to Nextcloud failed."
            fi
        fi

        if (( failed != 0 )); then
            notify_discord "$webhook" "❌ Folder Sync Failed" "Folder synchronization for **$name** returned an error." 15158332
            return 1
        fi
        return 0
    fi
}

###############################################################################
# LOCAL DUMP RETENTION CLEANUP
###############################################################################

cleanup_local() {
    local dir="$1"
    local days="$2"

    [[ -z "$dir" ]] && return 0
    [[ ! -d "$dir" ]] && return 0
    [[ -z "$days" ]] && return 0

    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        log "WARNING: Invalid local retention days value: $days"
        return 1
    fi

    log "Cleaning local dumps: $dir (> ${days} days)"

    if ! find "$dir" \
        -type f \
        -name '*.dump' \
        -mtime "+${days}" \
        -delete
    then
        log "WARNING: Local dump cleanup failed for $dir"
    fi

    local remaining
    remaining="$(
        find "$dir" \
            -type f \
            -name '*.dump' \
            | wc -l
    )"

    log "Remaining local dumps: $remaining"
}

###############################################################################
# PROCESS SITE
###############################################################################

process_site() {
    local site_prefix="$1"

    CURRENT_SITE="$site_prefix"

    local enable_var="${site_prefix}_ENABLE"

    if [[ "${!enable_var:-false}" != "true" ]]; then
        return 0
    fi

    ((TOTAL_SITES+=1))

    ###########################################################################
    # VARIABLES & REMOTE OVERRIDES
    ###########################################################################

    local name_var="${site_prefix}_NAME"
    local site_name="${!name_var:-$site_prefix}"

    local remote_gdrive_var="${site_prefix}_REMOTE_GDRIVE"
    local remote_nc_var="${site_prefix}_REMOTE_NEXTCLOUD"
    local remote_r2_var="${site_prefix}_REMOTE_R2"

    local current_remote_gdrive="${!remote_gdrive_var:-${REMOTE_GDRIVE:-}}"
    local current_remote_nc="${!remote_nc_var:-${REMOTE_NEXTCLOUD:-}}"
    local current_remote_r2="${!remote_r2_var:-${REMOTE_R2:-}}"

    local db_enable_var="${site_prefix}_DB_ENABLE"
    local db_url_var="${site_prefix}_DB_URL"
    local local_dir_var="${site_prefix}_DB_LOCAL_DIR"
    local local_ret_var="${site_prefix}_DB_LOCAL_RETENTION_DAYS"
    local remote_ret_var="${site_prefix}_DB_REMOTE_RETENTION_DAYS"

    local db_path_gdrive_var="${site_prefix}_DB_PATH_GDRIVE"
    local db_path_nc_var="${site_prefix}_DB_PATH_NEXTCLOUD"

    local r2_enable_var="${site_prefix}_R2_ENABLE"
    local r2_bucket_var="${site_prefix}_R2_BUCKET"
    local r2_path_gdrive_var="${site_prefix}_R2_PATH_GDRIVE"
    local r2_path_nc_var="${site_prefix}_R2_PATH_NEXTCLOUD"
    local r2_trash_gdrive_var="${site_prefix}_R2_TRASH_PATH_GDRIVE"
    local r2_trash_nc_var="${site_prefix}_R2_TRASH_PATH_NEXTCLOUD"
    local r2_trash_ret_var="${site_prefix}_R2_TRASH_RETENTION_DAYS"

    local folder_enable_var="${site_prefix}_FOLDER_ENABLE"
    [[ -z "${!folder_enable_var:-}" ]] && folder_enable_var="${site_prefix}_CDN_ENABLE"

    local folder_src_var="${site_prefix}_FOLDER_SRC"
    [[ -z "${!folder_src_var:-}" ]] && folder_src_var="${site_prefix}_CDN_LOCAL_DIR"
    [[ -z "${!folder_src_var:-}" ]] && folder_src_var="${site_prefix}_CDN_SRC"

    local folder_mode_var="${site_prefix}_FOLDER_MODE"
    [[ -z "${!folder_mode_var:-}" ]] && folder_mode_var="${site_prefix}_CDN_SYNC_MODE"

    local folder_archive_var="${site_prefix}_FOLDER_ARCHIVE"
    local folder_format_var="${site_prefix}_FOLDER_ARCHIVE_FORMAT"
    local folder_local_dir_var="${site_prefix}_FOLDER_ARCHIVE_LOCAL_DIR"
    local folder_ret_var="${site_prefix}_FOLDER_ARCHIVE_RETENTION_DAYS"

    local folder_path_gdrive_var="${site_prefix}_FOLDER_PATH_GDRIVE"
    [[ -z "${!folder_path_gdrive_var:-}" ]] && folder_path_gdrive_var="${site_prefix}_CDN_PATH_GDRIVE"

    local folder_path_nc_var="${site_prefix}_FOLDER_PATH_NEXTCLOUD"
    [[ -z "${!folder_path_nc_var:-}" ]] && folder_path_nc_var="${site_prefix}_CDN_PATH_NEXTCLOUD"

    local folder_trash_gdrive_var="${site_prefix}_FOLDER_TRASH_PATH_GDRIVE"
    [[ -z "${!folder_trash_gdrive_var:-}" ]] && folder_trash_gdrive_var="${site_prefix}_CDN_TRASH_PATH_GDRIVE"

    local folder_trash_nc_var="${site_prefix}_FOLDER_TRASH_PATH_NEXTCLOUD"
    [[ -z "${!folder_trash_nc_var:-}" ]] && folder_trash_nc_var="${site_prefix}_CDN_TRASH_PATH_NEXTCLOUD"

    local folder_trash_ret_var="${site_prefix}_FOLDER_TRASH_RETENTION_DAYS"
    [[ -z "${!folder_trash_ret_var:-}" ]] && folder_trash_ret_var="${site_prefix}_CDN_TRASH_RETENTION_DAYS"

    local webhook_var="${site_prefix}_DISCORD_WEBHOOK_URL"
    local webhook="${!webhook_var:-}"

    ###########################################################################
    # REMOTE TARGETS
    ###########################################################################

    local db_gdrive_target=""
    local db_nc_target=""

    local r2_src_target=""
    local r2_gdrive_target=""
    local r2_nc_target=""
    local r2_trash_gdrive_target=""
    local r2_trash_nc_target=""

    local folder_gdrive_target=""
    local folder_nc_target=""
    local folder_trash_gdrive_target=""
    local folder_trash_nc_target=""

    if [[ -n "${!db_path_gdrive_var:-}" ]]; then
        db_gdrive_target="$(format_target "$current_remote_gdrive" "${!db_path_gdrive_var}")"
    fi
    if [[ -n "${!db_path_nc_var:-}" ]]; then
        db_nc_target="$(format_target "$current_remote_nc" "${!db_path_nc_var}")"
    fi

    if [[ -n "${!r2_bucket_var:-}" ]]; then
        r2_src_target="$(format_target "$current_remote_r2" "${!r2_bucket_var}")"
    fi
    if [[ -n "${!r2_path_gdrive_var:-}" ]]; then
        r2_gdrive_target="$(format_target "$current_remote_gdrive" "${!r2_path_gdrive_var}")"
    fi
    if [[ -n "${!r2_path_nc_var:-}" ]]; then
        r2_nc_target="$(format_target "$current_remote_nc" "${!r2_path_nc_var}")"
    fi
    if [[ -n "${!r2_trash_gdrive_var:-}" ]]; then
        r2_trash_gdrive_target="$(format_target "$current_remote_gdrive" "${!r2_trash_gdrive_var}")"
    fi
    if [[ -n "${!r2_trash_nc_var:-}" ]]; then
        r2_trash_nc_target="$(format_target "$current_remote_nc" "${!r2_trash_nc_var}")"
    fi

    if [[ -n "${!folder_path_gdrive_var:-}" ]]; then
        folder_gdrive_target="$(format_target "$current_remote_gdrive" "${!folder_path_gdrive_var}")"
    fi
    if [[ -n "${!folder_path_nc_var:-}" ]]; then
        folder_nc_target="$(format_target "$current_remote_nc" "${!folder_path_nc_var}")"
    fi
    if [[ -n "${!folder_trash_gdrive_var:-}" ]]; then
        folder_trash_gdrive_target="$(format_target "$current_remote_gdrive" "${!folder_trash_gdrive_var}")"
    fi
    if [[ -n "${!folder_trash_nc_var:-}" ]]; then
        folder_trash_nc_target="$(format_target "$current_remote_nc" "${!folder_trash_nc_var}")"
    fi

    ###########################################################################
    # START SITE
    ###########################################################################

    notify_discord \
        "$webhook" \
        "🚀 Starting Backup: $site_name" \
        "Initiating backup procedures for **$site_name**." \
        3447003

    log "========== START SITE: $site_name =========="
    [[ -n "$current_remote_gdrive" ]] && log "  Remote GDrive    : $current_remote_gdrive"
    [[ -n "$current_remote_nc" ]]     && log "  Remote Nextcloud : $current_remote_nc"
    [[ -n "$current_remote_r2" ]]     && log "  Remote R2        : $current_remote_r2"

    local db_status=0
    local r2_status=0
    local folder_status=0

    local db_is_enabled=false
    if [[ "${!db_enable_var:-true}" != "false" && (-n "${!db_url_var:-}" || -n "${!local_dir_var:-}") ]]; then
        db_is_enabled=true
    fi

    local r2_is_enabled=false
    if [[ "${!r2_enable_var:-false}" == "true" ]]; then
        r2_is_enabled=true
    fi

    local folder_is_enabled=false
    if [[ "${!folder_enable_var:-false}" == "true" ]]; then
        folder_is_enabled=true
    fi

    # 1) Database
    if [[ "$db_is_enabled" == "true" ]]; then
        local remote_ret_default="${!remote_ret_var:-90}"
        local remote_ret_gdrive_var="${site_prefix}_DB_REMOTE_RETENTION_DAYS_GDRIVE"
        local remote_ret_gdrive="${!remote_ret_gdrive_var:-$remote_ret_default}"

        local remote_ret_nc_var="${site_prefix}_DB_REMOTE_RETENTION_DAYS_NEXTCLOUD"
        local remote_ret_nc="${!remote_ret_nc_var:-$remote_ret_default}"

        backup_site_db \
            "$site_name" \
            "${!db_url_var:-}" \
            "${!local_dir_var:-}" \
            "$remote_ret_gdrive" \
            "$remote_ret_nc" \
            "$db_gdrive_target" \
            "$db_nc_target" \
            "$webhook" || db_status=$?

        if [[ -n "${!local_dir_var:-}" ]]; then
            cleanup_local "${!local_dir_var}" "${!local_ret_var:-7}" || true
        fi
    fi

    # 2) R2 Media
    if [[ "$r2_is_enabled" == "true" ]]; then
        backup_site_r2 \
            "$site_name" \
            "$r2_src_target" \
            "$r2_gdrive_target" \
            "$r2_nc_target" \
            "$r2_trash_gdrive_target" \
            "$r2_trash_nc_target" \
            "${!r2_trash_ret_var:-}" \
            "$webhook" || r2_status=$?
    fi

    # 3) Local Folder / CDN
    if [[ "$folder_is_enabled" == "true" ]]; then
        local folder_mode="${!folder_mode_var:-sync}"
        if [[ "${!folder_archive_var:-false}" == "true" ]]; then
            folder_mode="archive"
        fi

        backup_site_folder \
            "$site_name" \
            "${!folder_src_var:-}" \
            "$folder_mode" \
            "${!folder_format_var:-tar.gz}" \
            "${!folder_local_dir_var:-}" \
            "${!folder_ret_var:-30}" \
            "$folder_gdrive_target" \
            "$folder_nc_target" \
            "$folder_trash_gdrive_target" \
            "$folder_trash_nc_target" \
            "${!folder_trash_ret_var:-60}" \
            "$webhook" || folder_status=$?
    fi

    ###########################################################################
    # AGGREGATE RESULT
    ###########################################################################

    local active_count=0
    local success_count=0
    local partial_count=0
    local failed_count=0

    if [[ "$db_is_enabled" == "true" ]]; then
        ((active_count+=1))
        if (( db_status == 0 )); then ((success_count+=1)); elif (( db_status == 2 )); then ((partial_count+=1)); else ((failed_count+=1)); fi
    fi

    if [[ "$r2_is_enabled" == "true" ]]; then
        ((active_count+=1))
        if (( r2_status == 0 )); then ((success_count+=1)); elif (( r2_status == 2 )); then ((partial_count+=1)); else ((failed_count+=1)); fi
    fi

    if [[ "$folder_is_enabled" == "true" ]]; then
        ((active_count+=1))
        if (( folder_status == 0 )); then ((success_count+=1)); elif (( folder_status == 2 )); then ((partial_count+=1)); else ((failed_count+=1)); fi
    fi

    local final_status="OK"
    local final_title="🏁 Backup Completed: $site_name"
    local final_color=3066993

    if (( active_count == 0 )); then
        final_status="EMPTY"
        final_title="⚪ No Modules Configured: $site_name"
        final_color=9807270
    elif (( failed_count == 0 && partial_count == 0 )); then
        ((SUCCESS_SITES+=1))
        final_status="OK"
        final_title="🏁 Backup Completed: $site_name"
        final_color=3066993
    elif (( success_count == 0 && partial_count == 0 )); then
        ((FAILED_SITES+=1))
        final_status="FAILED"
        final_title="❌ Backup Failed: $site_name"
        final_color=15158332
    else
        ((PARTIAL_SITES+=1))
        final_status="PARTIAL"
        final_title="⚠️ Partial Backup: $site_name"
        final_color=16776960
    fi

    log "========== END SITE: $site_name [$final_status] =========="

    local report_lines=""
    local db_msg="N/A"
    local r2_msg="N/A"
    local folder_msg="N/A"

    if [[ "$db_is_enabled" == "true" ]]; then
        db_msg="❌ FAILED"
        if (( db_status == 0 )); then db_msg="✅ OK"; elif (( db_status == 2 )); then db_msg="⚠️ PARTIAL"; fi
        report_lines+="**Database:** ${db_msg}\n"
    fi

    if [[ "$r2_is_enabled" == "true" ]]; then
        r2_msg="❌ FAILED"
        if (( r2_status == 0 )); then r2_msg="✅ OK"; elif (( r2_status == 2 )); then r2_msg="⚠️ PARTIAL"; fi
        report_lines+="**R2 Media:** ${r2_msg}\n"
    fi

    if [[ "$folder_is_enabled" == "true" ]]; then
        folder_msg="❌ FAILED"
        if (( folder_status == 0 )); then folder_msg="✅ OK"; elif (( folder_status == 2 )); then folder_msg="⚠️ PARTIAL"; fi
        report_lines+="**Folder / CDN:** ${folder_msg}\n"
    fi

    notify_discord \
        "$webhook" \
        "$final_title" \
        "${report_lines}\n**Log:** \`$BACKUP_LOG_FILE\`" \
        "$final_color"

    # Per-site Telegram notification
    local tg_token_var="${site_prefix}_TELEGRAM_BOT_TOKEN"
    local tg_chat_var="${site_prefix}_TELEGRAM_CHAT_ID"
    local site_tg_token="${!tg_token_var:-$TELEGRAM_BOT_TOKEN}"
    local site_tg_chat="${!tg_chat_var:-$TELEGRAM_CHAT_ID}"

    if [[ -n "$site_tg_token" && -n "$site_tg_chat" ]]; then
        local tg_msg="<b>${final_title}</b>\n"
        [[ "$db_is_enabled" == "true" ]] && tg_msg+="<b>Database:</b> ${db_msg}\n"
        [[ "$r2_is_enabled" == "true" ]] && tg_msg+="<b>R2 Media:</b> ${r2_msg}\n"
        [[ "$folder_is_enabled" == "true" ]] && tg_msg+="<b>Folder/CDN:</b> ${folder_msg}\n"
        tg_msg+="\n<i>Log:</i> <code>${BACKUP_LOG_FILE}</code>"
        notify_telegram "$site_tg_token" "$site_tg_chat" "$tg_msg"
    fi

    # Save state for HTML status dashboard
    python3 -c "
import json, sys, os
site = {
    'name': sys.argv[1],
    'status': sys.argv[2],
    'color': int(sys.argv[3]),
    'db_enabled': sys.argv[4] == 'true',
    'db_msg': sys.argv[5],
    'r2_enabled': sys.argv[6] == 'true',
    'r2_msg': sys.argv[7],
    'folder_enabled': sys.argv[8] == 'true',
    'folder_msg': sys.argv[9],
    'remote_gdrive': sys.argv[10],
    'remote_nc': sys.argv[11],
    'remote_r2': sys.argv[12],
    'timestamp': sys.argv[13]
}
path = sys.argv[14]
data = []
if os.path.exists(path):
    try:
        with open(path, 'r') as f: data = json.load(f)
    except: pass
data.append(site)
with open(path, 'w') as f: json.dump(data, f, indent=2)
" "$site_name" "$final_status" "$final_color" "$db_is_enabled" "${db_msg}" "$r2_is_enabled" "${r2_msg}" "$folder_is_enabled" "${folder_msg}" "$current_remote_gdrive" "$current_remote_nc" "$current_remote_r2" "$(date "+%Y-%m-%d %H:%M:%S")" "$SITES_STATUS_JSON" 2>/dev/null || true

    CURRENT_OPERATION=""
    CURRENT_SITE=""

    return 0
}

###############################################################################
# MAIN ENTRYPOINT
###############################################################################

main() {
    rotate_log_if_needed
    echo "[]" > "$SITES_STATUS_JSON"

    log "============================================================"
    log "Starting VPS Backup Manager Session"
    log "============================================================"

    if ! check_dependencies; then
        log "ERROR: Missing system dependencies."
        exit 1
    fi

    log "Scanning configured sites..."

    local sites=()

    while IFS= read -r prefix; do
        [[ -n "$prefix" ]] && sites+=("$prefix")
    done < <(
        (compgen -v | grep -E '^(SITE|SITO)[0-9]+_ENABLE$' || true) |
            sed 's/_ENABLE$//' |
            sort -V -u
    )

    if (( ${#sites[@]} == 0 )); then
        log "WARNING: No SITE<N>_ENABLE site configurations found."
        exit 0
    fi

    local site

    for site in "${sites[@]}"; do
        if ! process_site "$site"; then
            log "CRITICAL ERROR: Processing for $site aborted unexpectedly."
            ((FAILED_SITES+=1))
            CURRENT_SITE=""
            CURRENT_OPERATION=""
        fi
    done

    log "============================================================"
    log "Backup Session Finished"
    log "Total Sites : $TOTAL_SITES"
    log "Successful  : $SUCCESS_SITES"
    log "Partial     : $PARTIAL_SITES"
    log "Failed      : $FAILED_SITES"
    log "============================================================"

    # Generate public read-only HTML dashboard
    if [[ -f "${SCRIPT_DIR}/generate_report.py" ]]; then
        log "Generating HTML dashboard: $BACKUP_HTML_FILE"
        python3 "${SCRIPT_DIR}/generate_report.py" "$SITES_STATUS_JSON" "$BACKUP_LOG_FILE" "$BACKUP_HTML_FILE" || log "WARNING: Failed to generate HTML report."
    fi

    # Global Telegram summary & log document delivery
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        local tg_summary="🛡️ <b>VPS Backup Manager — Session Finished</b>\n\n"
        tg_summary+="• Total Sites: <b>${TOTAL_SITES}</b>\n"
        tg_summary+="• Successful: <b>${SUCCESS_SITES}</b> ✅\n"
        tg_summary+="• Partial: <b>${PARTIAL_SITES}</b> ⚠️\n"
        tg_summary+="• Failed: <b>${FAILED_SITES}</b> ❌\n\n"
        tg_summary+="HTML Status dashboard updated."
        notify_telegram "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "$tg_summary"

        if [[ "$TELEGRAM_SEND_LOG_DOCUMENT" == "true" && -f "$BACKUP_LOG_FILE" ]]; then
            send_telegram_document "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "$BACKUP_LOG_FILE" "VPS Backup Session Log"
        fi
    fi

    rotate_log_if_needed

    if (( FAILED_SITES > 0 || PARTIAL_SITES > 0 )); then
        return 1
    fi

    return 0
}

main "$@"

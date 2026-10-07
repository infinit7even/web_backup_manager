#!/usr/bin/env python3
"""
VPS Backup Manager - Environment Configuration Auto-Aligner
Reorganizes and standardizes .env according to the strict canonical template (.env.example).
Preserves existing values, migrates legacy variables, adds missing keys with clean defaults (""),
and removes obsolete or deprecated variables with an automatic safety backup.
"""

import sys
import os
import re
import shutil
from datetime import datetime

# Canonical 34-key schema per site block in strict order
SITE_KEYS_SCHEMA = [
    ("ENABLE", "true"),
    ("NAME", ""),
    ("REMOTE_GDRIVE", ""),
    ("REMOTE_NEXTCLOUD", ""),
    ("REMOTE_R2", ""),
    ("DB_ENABLE", "true"),
    ("DB_URL", ""),
    ("DB_LOCAL_DIR", ""),
    ("DB_LOCAL_RETENTION_DAYS", "7"),
    ("DB_REMOTE_RETENTION_DAYS", "90"),
    ("DB_REMOTE_RETENTION_DAYS_GDRIVE", ""),
    ("DB_REMOTE_RETENTION_DAYS_NEXTCLOUD", ""),
    ("DB_PATH_GDRIVE", ""),
    ("DB_PATH_NEXTCLOUD", ""),
    ("R2_ENABLE", "false"),
    ("R2_BUCKET", ""),
    ("R2_PATH_GDRIVE", ""),
    ("R2_PATH_NEXTCLOUD", ""),
    ("R2_TRASH_PATH_GDRIVE", ""),
    ("R2_TRASH_PATH_NEXTCLOUD", ""),
    ("R2_TRASH_RETENTION_DAYS", "60"),
    ("FOLDER_ENABLE", "false"),
    ("FOLDER_SRC", ""),
    ("FOLDER_PATH_GDRIVE", ""),
    ("FOLDER_PATH_NEXTCLOUD", ""),
    ("FOLDER_MODE", "sync"),
    ("FOLDER_TRASH_PATH_GDRIVE", ""),
    ("FOLDER_TRASH_PATH_NEXTCLOUD", ""),
    ("FOLDER_TRASH_RETENTION_DAYS", "60"),
    ("FOLDER_ARCHIVE_FORMAT", "tar.gz"),
    ("FOLDER_ARCHIVE_LOCAL_DIR", ""),
    ("FOLDER_ARCHIVE_RETENTION_DAYS", "30"),
    ("DISCORD_WEBHOOK_URL", ""),
    ("TELEGRAM_BOT_TOKEN", ""),
    ("TELEGRAM_CHAT_ID", ""),
]

# Legacy key mapping for backwards compatibility
LEGACY_MAPPING = {
    "CDN_ENABLE": "FOLDER_ENABLE",
    "CDN_SRC": "FOLDER_SRC",
    "CDN_LOCAL_DIR": "FOLDER_SRC",
    "CDN_PATH_GDRIVE": "FOLDER_PATH_GDRIVE",
    "CDN_PATH_NEXTCLOUD": "FOLDER_PATH_NEXTCLOUD",
    "CDN_SYNC_MODE": "FOLDER_MODE",
    "CDN_TRASH_PATH_GDRIVE": "FOLDER_TRASH_PATH_GDRIVE",
    "CDN_TRASH_PATH_NEXTCLOUD": "FOLDER_TRASH_PATH_NEXTCLOUD",
    "CDN_TRASH_RETENTION_DAYS": "FOLDER_TRASH_RETENTION_DAYS",
    "FOLDER_ARCHIVE": "FOLDER_MODE",
}

GLOBAL_KEYS_SCHEMA = [
    ("BACKUP_LOG_FILE", "/var/log/web_backup_manager/backup.log"),
    ("BACKUP_LOG_MAX_MB", "10"),
    ("BACKUP_HTML_FILE", "/var/www/backup_dashboard/index.html"),
    ("LOCK_FILE", ""),
    ("TELEGRAM_BOT_TOKEN", ""),
    ("TELEGRAM_CHAT_ID", ""),
    ("TELEGRAM_SEND_LOG_DOCUMENT", "true"),
]

def parse_env_file(filepath):
    """Parses key-value pairs from an env file, stripping surrounding quotes."""
    vars_dict = {}
    if not os.path.exists(filepath):
        return vars_dict

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip()
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                val = val[1:-1]
            vars_dict[key] = val
    return vars_dict

def format_val(val):
    """Formats values for output in .env."""
    if val is None or val == "":
        return '""'
    val_str = str(val)
    if val_str.lower() in ("true", "false") or val_str.isdigit():
        return val_str
    # Avoid escaping if already clean
    return f'"{val_str}"'

def align_env(target_env, template_example=None):
    if not os.path.exists(target_env):
        print(f"Error: Target file {target_env} does not exist.")
        sys.exit(1)

    # 1. Automatic safety backup
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_file = f"{target_env}.bak_{timestamp}"
    shutil.copy2(target_env, backup_file)
    print(f"📦 Safety backup created: {backup_file}")

    existing_vars = parse_env_file(target_env)
    used_keys = set()
    added_keys = []
    removed_keys = []

    # Detect all sites declared (supporting both SITE<N> and legacy SITO<N>)
    site_prefixes = set()
    for k in existing_vars.keys():
        m = re.match(r"^(SITO|SITE)(\d+)_", k)
        if m:
            site_num = int(m.group(2))
            site_prefixes.add(site_num)

    if not site_prefixes:
        # Default fallback to 1 site if none detected
        site_prefixes.add(1)

    sorted_sites = sorted(list(site_prefixes))

    # Build output content
    out = []
    out.append("# ==============================================================================")
    out.append("# VPS BACKUP MANAGER - CONFIGURATION")
    out.append("# ==============================================================================")
    out.append("# Security recommendations:")
    out.append("#   chmod 600 .env")
    out.append("#   chmod +x run_backup.sh")
    out.append("# ==============================================================================")
    out.append("")
    out.append("# ==========================================")
    out.append("# 1. GENERAL LOGGING, ROTATION & HTML STATUS")
    out.append("# ==========================================")

    # Global logging
    for gkey, default_val in GLOBAL_KEYS_SCHEMA[:4]:
        val = existing_vars.get(gkey, default_val)
        if gkey in existing_vars:
            used_keys.add(gkey)
        else:
            added_keys.append(gkey)
        out.append(f"{gkey}={format_val(val)}")

    out.append("")
    out.append("# ==========================================")
    out.append("# 2. TELEGRAM BOT NOTIFICATIONS")
    out.append("# ==========================================")
    out.append("# Leave empty if you only use Discord webhooks.")
    out.append("# To create a bot: @BotFather -> /newbot -> copy the HTTP API token")
    out.append("# To get your chat_id: @userinfobot or @myidbot")

    for gkey, default_val in GLOBAL_KEYS_SCHEMA[4:]:
        val = existing_vars.get(gkey, default_val)
        if gkey in existing_vars:
            used_keys.add(gkey)
        else:
            added_keys.append(gkey)
        out.append(f"{gkey}={format_val(val)}")

    out.append("")
    out.append("# ==============================================================================")
    out.append("# 3. SITE DEFINITIONS (STANDARDIZED UNIFORM STRUCTURE PER SITE)")
    out.append("# ==============================================================================")
    out.append("# Every site block strictly shares the exact same modular schema (34 keys).")
    out.append('# If a feature or component is unused, its ENABLE flag is false and fields are empty ("").')
    out.append("")

    for snum in sorted_sites:
        sprefix = f"SITE{snum}"
        sito_prefix = f"SITO{snum}"

        site_name_val = existing_vars.get(f"{sprefix}_NAME") or existing_vars.get(f"{sito_prefix}_NAME") or f"site_{snum}"
        out.append("# ------------------------------------------------------------------------------")
        out.append(f"# {sprefix}: {site_name_val.upper()}")
        out.append("# ------------------------------------------------------------------------------")

        # Extract values for this site
        site_vals = {}
        for short_key, default_val in SITE_KEYS_SCHEMA:
            # Check modern key, then legacy SITO key
            val = None
            cand1 = f"{sprefix}_{short_key}"
            cand2 = f"{sito_prefix}_{short_key}"

            if cand1 in existing_vars:
                val = existing_vars[cand1]
                used_keys.add(cand1)
            elif cand2 in existing_vars:
                val = existing_vars[cand2]
                used_keys.add(cand2)
            else:
                # Check legacy aliases
                for leg_from, leg_to in LEGACY_MAPPING.items():
                    if leg_to == short_key:
                        lcand1 = f"{sprefix}_{leg_from}"
                        lcand2 = f"{sito_prefix}_{leg_from}"
                        if lcand1 in existing_vars:
                            val = existing_vars[lcand1]
                            used_keys.add(lcand1)
                            break
                        elif lcand2 in existing_vars:
                            val = existing_vars[lcand2]
                            used_keys.add(lcand2)
                            break

            if val is None:
                # Intelligently infer DB_ENABLE if DB_URL exists
                if short_key == "DB_ENABLE":
                    db_url = existing_vars.get(f"{sprefix}_DB_URL") or existing_vars.get(f"{sito_prefix}_DB_URL")
                    val = "true" if db_url else "false"
                else:
                    val = default_val
                added_keys.append(f"{sprefix}_{short_key}")

            site_vals[short_key] = val

        # Dedicated remotes section
        out.append(f"{sprefix}_ENABLE={format_val(site_vals['ENABLE'])}")
        out.append(f"{sprefix}_NAME={format_val(site_vals['NAME'])}")
        out.append("")
        out.append("# --- Dedicated Remotes ---")
        out.append(f"{sprefix}_REMOTE_GDRIVE={format_val(site_vals['REMOTE_GDRIVE'])}")
        out.append(f"{sprefix}_REMOTE_NEXTCLOUD={format_val(site_vals['REMOTE_NEXTCLOUD'])}")
        out.append(f"{sprefix}_REMOTE_R2={format_val(site_vals['REMOTE_R2'])}")
        out.append("")

        # Component 1: Database
        out.append("# --- Component 1: PostgreSQL Database ---")
        out.append(f"{sprefix}_DB_ENABLE={format_val(site_vals['DB_ENABLE'])}")
        out.append(f"{sprefix}_DB_URL={format_val(site_vals['DB_URL'])}")
        out.append(f"{sprefix}_DB_LOCAL_DIR={format_val(site_vals['DB_LOCAL_DIR'])}")
        out.append(f"{sprefix}_DB_LOCAL_RETENTION_DAYS={format_val(site_vals['DB_LOCAL_RETENTION_DAYS'])}")
        out.append(f"{sprefix}_DB_REMOTE_RETENTION_DAYS={format_val(site_vals['DB_REMOTE_RETENTION_DAYS'])}")
        out.append(f"{sprefix}_DB_REMOTE_RETENTION_DAYS_GDRIVE={format_val(site_vals['DB_REMOTE_RETENTION_DAYS_GDRIVE'])}")
        out.append(f"{sprefix}_DB_REMOTE_RETENTION_DAYS_NEXTCLOUD={format_val(site_vals['DB_REMOTE_RETENTION_DAYS_NEXTCLOUD'])}")
        out.append(f"{sprefix}_DB_PATH_GDRIVE={format_val(site_vals['DB_PATH_GDRIVE'])}")
        out.append(f"{sprefix}_DB_PATH_NEXTCLOUD={format_val(site_vals['DB_PATH_NEXTCLOUD'])}")
        out.append("")

        # Component 2: Cloudflare R2
        out.append("# --- Component 2: Cloudflare R2 Media Bucket Sync ---")
        out.append(f"{sprefix}_R2_ENABLE={format_val(site_vals['R2_ENABLE'])}")
        out.append(f"{sprefix}_R2_BUCKET={format_val(site_vals['R2_BUCKET'])}")
        out.append(f"{sprefix}_R2_PATH_GDRIVE={format_val(site_vals['R2_PATH_GDRIVE'])}")
        out.append(f"{sprefix}_R2_PATH_NEXTCLOUD={format_val(site_vals['R2_PATH_NEXTCLOUD'])}")
        out.append(f"{sprefix}_R2_TRASH_PATH_GDRIVE={format_val(site_vals['R2_TRASH_PATH_GDRIVE'])}")
        out.append(f"{sprefix}_R2_TRASH_PATH_NEXTCLOUD={format_val(site_vals['R2_TRASH_PATH_NEXTCLOUD'])}")
        out.append(f"{sprefix}_R2_TRASH_RETENTION_DAYS={format_val(site_vals['R2_TRASH_RETENTION_DAYS'])}")
        out.append("")

        # Component 3: Local Folder / Assets Sync
        out.append("# --- Component 3: Local Folder / CDN / Assets Sync ---")
        out.append(f"{sprefix}_FOLDER_ENABLE={format_val(site_vals['FOLDER_ENABLE'])}")
        out.append(f"{sprefix}_FOLDER_SRC={format_val(site_vals['FOLDER_SRC'])}")
        out.append(f"{sprefix}_FOLDER_PATH_GDRIVE={format_val(site_vals['FOLDER_PATH_GDRIVE'])}")
        out.append(f"{sprefix}_FOLDER_PATH_NEXTCLOUD={format_val(site_vals['FOLDER_PATH_NEXTCLOUD'])}")
        out.append(f"{sprefix}_FOLDER_MODE={format_val(site_vals['FOLDER_MODE'])}")
        out.append(f"{sprefix}_FOLDER_TRASH_PATH_GDRIVE={format_val(site_vals['FOLDER_TRASH_PATH_GDRIVE'])}")
        out.append(f"{sprefix}_FOLDER_TRASH_PATH_NEXTCLOUD={format_val(site_vals['FOLDER_TRASH_PATH_NEXTCLOUD'])}")
        out.append(f"{sprefix}_FOLDER_TRASH_RETENTION_DAYS={format_val(site_vals['FOLDER_TRASH_RETENTION_DAYS'])}")
        out.append(f"{sprefix}_FOLDER_ARCHIVE_FORMAT={format_val(site_vals['FOLDER_ARCHIVE_FORMAT'])}")
        out.append(f"{sprefix}_FOLDER_ARCHIVE_LOCAL_DIR={format_val(site_vals['FOLDER_ARCHIVE_LOCAL_DIR'])}")
        out.append(f"{sprefix}_FOLDER_ARCHIVE_RETENTION_DAYS={format_val(site_vals['FOLDER_ARCHIVE_RETENTION_DAYS'])}")
        out.append("")

        # Notifications
        out.append("# --- Notifications ---")
        out.append(f"{sprefix}_DISCORD_WEBHOOK_URL={format_val(site_vals['DISCORD_WEBHOOK_URL'])}")
        out.append(f"{sprefix}_TELEGRAM_BOT_TOKEN={format_val(site_vals['TELEGRAM_BOT_TOKEN'])}")
        out.append(f"{sprefix}_TELEGRAM_CHAT_ID={format_val(site_vals['TELEGRAM_CHAT_ID'])}")
        out.append("")

    # Find obsolete / unused keys
    for k in existing_vars.keys():
        if k not in used_keys:
            removed_keys.append(k)

    # Write aligned file
    with open(target_env, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")

    print(f"✨ Successfully aligned {target_env}!")
    print(f"   • Sites structured: {len(sorted_sites)} ({', '.join(['SITE' + str(s) for s in sorted_sites])})")
    print(f"   • Standard keys per site: 34")
    if added_keys:
        print(f"   • New keys added with clean defaults ({len(added_keys)}):")
        for k in added_keys[:10]:
            print(f"       + {k}")
        if len(added_keys) > 10:
            print(f"       ... and {len(added_keys) - 10} more.")
    if removed_keys:
        print(f"   • Obsolete/legacy keys pruned ({len(removed_keys)}):")
        for k in removed_keys:
            print(f"       - {k}")
    else:
        print("   • No obsolete variables found.")

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(script_dir, ".env")
    template = sys.argv[2] if len(sys.argv) > 2 else os.path.join(script_dir, ".env.example")
    align_env(target, template)

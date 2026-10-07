#!/usr/bin/env python3
import sys
import os
import json
import html
from datetime import datetime

def generate_html(sites_json_path, log_file_path, output_html_path):
    sites = []
    if os.path.exists(sites_json_path):
        try:
            with open(sites_json_path, "r", encoding="utf-8") as f:
                sites = json.load(f)
        except Exception as e:
            print(f"Error reading sites JSON: {e}", file=sys.stderr)

    # Last log lines
    log_lines = []
    if os.path.exists(log_file_path):
        try:
            with open(log_file_path, "r", encoding="utf-8", errors="replace") as f:
                all_lines = f.readlines()
                log_lines = all_lines[-300:]  # last 300 lines
        except Exception as e:
            log_lines = [f"Error reading log file: {e}"]

    # Overall system health
    total_sites = len(sites)
    success_sites = sum(1 for s in sites if s.get("status") in ["OK", "SUCCESS"])
    partial_sites = sum(1 for s in sites if s.get("status") in ["PARTIAL", "PARZIALE"])
    failed_sites = sum(1 for s in sites if s.get("status") in ["FAILED", "FALLITO"])

    if failed_sites > 0:
        global_status = "CRITICAL FAILURE"
        global_class = "status-crit"
        global_desc = f"{failed_sites} site(s) failed during backup"
    elif partial_sites > 0:
        global_status = "PARTIAL BACKUP"
        global_class = "status-warn"
        global_desc = f"{partial_sites} site(s) completed with warnings"
    elif total_sites > 0:
        global_status = "ALL SYSTEMS OPERATIONAL"
        global_class = "status-ok"
        global_desc = f"All {total_sites} site(s) backed up successfully"
    else:
        global_status = "NO SITES CONFIGURED"
        global_class = "status-neutral"
        global_desc = "No active sites found"

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Generate site cards
    cards_html = []
    for s in sites:
        name = html.escape(s.get("name", "Unknown"))
        raw_status = s.get("status", "UNKNOWN").upper()
        if raw_status in ["OK", "SUCCESS"]:
            status_label = "OK"
            st_class = "badge-ok"
        elif raw_status in ["PARTIAL", "PARZIALE"]:
            status_label = "PARTIAL"
            st_class = "badge-warn"
        else:
            status_label = "FAILED"
            st_class = "badge-crit"

        time_str = html.escape(s.get("timestamp", now_str))

        remotes = []
        if s.get("remote_gdrive"): remotes.append(f"GDrive: <code>{html.escape(s['remote_gdrive'])}</code>")
        if s.get("remote_nc"): remotes.append(f"Nextcloud: <code>{html.escape(s['remote_nc'])}</code>")
        if s.get("remote_r2"): remotes.append(f"R2: <code>{html.escape(s['remote_r2'])}</code>")
        remotes_str = " • ".join(remotes) if remotes else "<em>No specific remote</em>"

        modules_html = []
        if s.get("db_enabled"):
            db_msg = html.escape(s.get("db_msg", "Active"))
            is_ok = "OK" in db_msg or "SUCCESS" in db_msg.upper()
            modules_html.append(f"""
            <div class="module-row">
                <span class="module-icon">💾</span>
                <div class="module-info">
                    <strong>PostgreSQL Database</strong>
                    <div class="module-desc">{db_msg}</div>
                </div>
                <span class="badge { 'badge-ok' if is_ok else 'badge-crit' }">{ 'OK' if is_ok else 'FAILED' }</span>
            </div>
            """)

        if s.get("r2_enabled"):
            r2_msg = html.escape(s.get("r2_msg", "Active"))
            is_ok = "OK" in r2_msg or "SUCCESS" in r2_msg.upper()
            modules_html.append(f"""
            <div class="module-row">
                <span class="module-icon">☁️</span>
                <div class="module-info">
                    <strong>Cloudflare R2 Bucket</strong>
                    <div class="module-desc">{r2_msg}</div>
                </div>
                <span class="badge { 'badge-ok' if is_ok else 'badge-crit' }">{ 'OK' if is_ok else 'FAILED' }</span>
            </div>
            """)

        if s.get("folder_enabled"):
            f_msg = html.escape(s.get("folder_msg", "Active"))
            is_ok = "OK" in f_msg or "SUCCESS" in f_msg.upper()
            modules_html.append(f"""
            <div class="module-row">
                <span class="module-icon">📁</span>
                <div class="module-info">
                    <strong>Local Folder / CDN</strong>
                    <div class="module-desc">{f_msg}</div>
                </div>
                <span class="badge { 'badge-ok' if is_ok else 'badge-crit' }">{ 'OK' if is_ok else 'FAILED' }</span>
            </div>
            """)

        if not modules_html:
            modules_html.append('<div class="module-empty">No modules enabled</div>')

        cards_html.append(f"""
        <div class="site-card border-{st_class}">
            <div class="site-header">
                <div>
                    <h3 class="site-title">{name}</h3>
                    <div class="site-remotes">{remotes_str}</div>
                </div>
                <span class="badge {st_class}">{status_label}</span>
            </div>
            <div class="site-body">
                {''.join(modules_html)}
            </div>
            <div class="site-footer">
                <span>Last Backup: {time_str}</span>
            </div>
        </div>
        """)

    # Format log lines with syntax highlights
    formatted_logs = []
    for line in log_lines:
        safe_line = html.escape(line.rstrip())
        css_line = "log-line"
        upper = safe_line.upper()
        if "ERROR" in upper or "ERRORE" in upper or "FAILED" in upper or "FALLITO" in upper:
            css_line += " log-err"
        elif "WARN" in upper or "AVVISO" in upper or "ALERT" in upper:
            css_line += " log-warn"
        elif "OK" in upper or "COMPLETED" in upper or "DUMP CREATED" in upper or "SUCCESS" in upper:
            css_line += " log-ok"
        elif "=====" in safe_line or "---" in safe_line:
            css_line += " log-header"
        formatted_logs.append(f'<div class="{css_line}">{safe_line}</div>')

    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="300">
    <title>VPS Backup Manager — System Status</title>
    <style>
        :root {{
            --bg: #090d16;
            --surface: #111827;
            --surface-hover: #1a2234;
            --border: #1f293d;
            --text-primary: #f9fafb;
            --text-secondary: #9ca3af;
            --text-muted: #6b7280;
            --accent-green: #10b981;
            --accent-green-bg: rgba(16, 185, 129, 0.12);
            --accent-yellow: #f59e0b;
            --accent-yellow-bg: rgba(245, 158, 11, 0.12);
            --accent-red: #ef4444;
            --accent-red-bg: rgba(239, 68, 68, 0.12);
            --accent-blue: #3b82f6;
            --radius: 12px;
        }}
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        body {{
            background: var(--bg);
            color: var(--text-primary);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            padding: 32px 20px 80px;
            line-height: 1.5;
        }}
        .container {{
            max-width: 1200px;
            margin: 0 auto;
        }}
        header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 20px;
            margin-bottom: 32px;
            padding-bottom: 24px;
            border-bottom: 1px solid var(--border);
        }}
        .brand {{
            display: flex;
            align-items: center;
            gap: 14px;
        }}
        .brand-icon {{
            font-size: 32px;
            background: var(--surface);
            padding: 10px;
            border-radius: var(--radius);
            border: 1px solid var(--border);
        }}
        h1 {{
            font-size: 26px;
            font-weight: 800;
            letter-spacing: -0.5px;
        }}
        .subtitle {{
            color: var(--text-secondary);
            font-size: 14px;
        }}
        .global-status {{
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 8px 16px;
            border-radius: 999px;
            font-size: 14px;
            font-weight: 700;
            letter-spacing: 0.5px;
            text-transform: uppercase;
        }}
        .status-ok {{ background: var(--accent-green-bg); color: var(--accent-green); border: 1px solid rgba(16, 185, 129, 0.3); }}
        .status-warn {{ background: var(--accent-yellow-bg); color: var(--accent-yellow); border: 1px solid rgba(245, 158, 11, 0.3); }}
        .status-crit {{ background: var(--accent-red-bg); color: var(--accent-red); border: 1px solid rgba(239, 68, 68, 0.3); }}
        .status-neutral {{ background: var(--surface); color: var(--text-secondary); border: 1px solid var(--border); }}
        .status-dot {{ width: 8px; height: 8px; border-radius: 50%; background: currentColor; }}

        .stats-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 16px;
            margin-bottom: 32px;
        }}
        .stat-card {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius);
            padding: 18px 20px;
        }}
        .stat-label {{
            color: var(--text-secondary);
            font-size: 13px;
            font-weight: 500;
            margin-bottom: 6px;
        }}
        .stat-val {{
            font-size: 28px;
            font-weight: 800;
        }}

        .section-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 18px;
        }}
        h2 {{
            font-size: 19px;
            font-weight: 700;
        }}

        .sites-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 20px;
            margin-bottom: 40px;
        }}
        .site-card {{
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: var(--radius);
            overflow: hidden;
            display: flex;
            flex-direction: column;
            transition: border-color 0.2s;
        }}
        .site-card:hover {{
            border-color: #2e3d5b;
        }}
        .site-header {{
            padding: 16px 20px;
            background: rgba(255, 255, 255, 0.02);
            border-bottom: 1px solid var(--border);
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            gap: 12px;
        }}
        .site-title {{
            font-size: 17px;
            font-weight: 700;
            margin-bottom: 4px;
        }}
        .site-remotes {{
            font-size: 12px;
            color: var(--text-secondary);
        }}
        .site-remotes code {{
            background: rgba(255, 255, 255, 0.06);
            padding: 2px 5px;
            border-radius: 4px;
            color: var(--text-primary);
        }}
        .site-body {{
            padding: 18px 20px;
            flex: 1;
            display: flex;
            flex-direction: column;
            gap: 12px;
        }}
        .module-row {{
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 10px 12px;
            background: rgba(0, 0, 0, 0.2);
            border: 1px solid rgba(255, 255, 255, 0.03);
            border-radius: 8px;
        }}
        .module-icon {{ font-size: 20px; }}
        .module-info {{ flex: 1; font-size: 13px; }}
        .module-desc {{ color: var(--text-secondary); font-size: 12px; }}

        .site-footer {{
            padding: 10px 20px;
            background: rgba(0, 0, 0, 0.25);
            border-top: 1px solid var(--border);
            font-size: 12px;
            color: var(--text-muted);
            display: flex;
            justify-content: space-between;
        }}

        .badge {{
            padding: 4px 10px;
            border-radius: 6px;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.3px;
        }}
        .badge-ok {{ background: var(--accent-green-bg); color: var(--accent-green); border: 1px solid rgba(16, 185, 129, 0.2); }}
        .badge-warn {{ background: var(--accent-yellow-bg); color: var(--accent-yellow); border: 1px solid rgba(245, 158, 11, 0.2); }}
        .badge-crit {{ background: var(--accent-red-bg); color: var(--accent-red); border: 1px solid rgba(239, 68, 68, 0.2); }}

        /* Terminal Logs */
        .terminal {{
            background: #030712;
            border: 1px solid var(--border);
            border-radius: var(--radius);
            overflow: hidden;
            font-family: ui-monospace, SFMono-Regular, "JetBrains Mono", Menlo, Consolas, monospace;
        }}
        .terminal-header {{
            background: #0d131f;
            padding: 12px 16px;
            border-bottom: 1px solid var(--border);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }}
        .terminal-dots {{
            display: flex;
            gap: 6px;
        }}
        .dot {{ width: 10px; height: 10px; border-radius: 50%; }}
        .dot-red {{ background: #ef4444; }}
        .dot-yellow {{ background: #f59e0b; }}
        .dot-green {{ background: #10b981; }}
        .terminal-title {{ font-size: 12px; color: var(--text-secondary); }}
        .terminal-search {{
            background: #1f293d;
            border: 1px solid var(--border);
            color: var(--text-primary);
            padding: 4px 10px;
            border-radius: 6px;
            font-size: 12px;
            outline: none;
        }}
        .terminal-body {{
            max-height: 480px;
            overflow-y: auto;
            padding: 16px;
            font-size: 12px;
            line-height: 1.6;
        }}
        .log-line {{ color: #cbd5e1; white-space: pre-wrap; word-break: break-all; }}
        .log-ok {{ color: #34d399; }}
        .log-warn {{ color: #fbbf24; }}
        .log-err {{ color: #f87171; font-weight: bold; }}
        .log-header {{ color: #60a5fa; font-weight: 600; margin-top: 4px; }}

        footer {{
            margin-top: 40px;
            text-align: center;
            font-size: 13px;
            color: var(--text-muted);
        }}
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="brand">
                <div class="brand-icon">🛡️</div>
                <div>
                    <h1>Backup Manager VPS</h1>
                    <div class="subtitle">Cloud &amp; Offsite Backup Status • Auto-updating Dashboard</div>
                </div>
            </div>
            <div class="global-status {global_class}">
                <span class="status-dot"></span>
                <span>{global_status}</span>
            </div>
        </header>

        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-label">Monitored Sites</div>
                <div class="stat-val">{total_sites}</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Successful Backups</div>
                <div class="stat-val" style="color: var(--accent-green);">{success_sites}</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Partial / Warnings</div>
                <div class="stat-val" style="color: var(--accent-yellow);">{partial_sites}</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Failed</div>
                <div class="stat-val" style="color: var(--accent-red);">{failed_sites}</div>
            </div>
        </div>

        <div class="section-header">
            <h2>Sites &amp; Backup Services</h2>
            <span style="font-size: 13px; color: var(--text-secondary);">Generated at {now_str}</span>
        </div>

        <div class="sites-grid">
            {''.join(cards_html) if cards_html else '<p style="color: var(--text-muted)">No configured sites.</p>'}
        </div>

        <div class="section-header">
            <h2>Live System Logs</h2>
            <span style="font-size: 13px; color: var(--text-secondary);">Last 300 lines</span>
        </div>

        <div class="terminal">
            <div class="terminal-header">
                <div class="terminal-dots">
                    <div class="dot dot-red"></div>
                    <div class="dot dot-yellow"></div>
                    <div class="dot dot-green"></div>
                </div>
                <div class="terminal-title">backup.log</div>
                <input type="text" id="logFilter" class="terminal-search" placeholder="Filter logs..." onkeyup="filterLog()">
            </div>
            <div class="terminal-body" id="logContainer">
                {''.join(formatted_logs)}
            </div>
        </div>

        <footer>
            Backup Manager VPS • Read-Only Mode • Served by Caddy Server
        </footer>
    </div>

    <script>
        function filterLog() {{
            const val = document.getElementById('logFilter').value.toLowerCase();
            const lines = document.querySelectorAll('#logContainer .log-line');
            lines.forEach(line => {{
                line.style.display = line.textContent.toLowerCase().includes(val) ? '' : 'none';
            }});
        }}
    </script>
</body>
</html>
"""

    os.makedirs(os.path.dirname(os.path.abspath(output_html_path)), exist_ok=True)
    with open(output_html_path, "w", encoding="utf-8") as f:
        f.write(html_content)
    print(f"HTML status report generated: {output_html_path}")

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: generate_report.py <sites_json_path> <log_file_path> <output_html_path>")
        sys.exit(1)
    generate_html(sys.argv[1], sys.argv[2], sys.argv[3])

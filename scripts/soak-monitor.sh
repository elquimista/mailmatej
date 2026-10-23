#!/bin/bash
# Samples a running MailMateJ Dev for scale and soak tests (M5): every INTERVAL seconds, one CSV line of
# elapsed seconds, messages stored, messages fully downloaded, resident memory (MB), CPU %, threads and
# open TCP connections.
#   scripts/soak-monitor.sh <data dir> [interval seconds] > samples.csv
# The data dir is the one the app runs with (MMJ_DATA_DIR). Stops when the app quits.
set -euo pipefail
DATA="$1"
INTERVAL="${2:-10}"
DB="$DATA/mail.sqlite"
PROCESS="${MMJ_PROCESS:-MailMateJ Dev.app/Contents/MacOS/MailMateJ}"  # MMJ_PROCESS: another build's path

echo "seconds,messages,downloaded,rss_mb,cpu_percent,threads,tcp"
start=$(date +%s)
while PID=$(pgrep -f "$PROCESS" | head -1); do
    now=$(date +%s)
    counts=$(sqlite3 -readonly "$DB" "SELECT COUNT(*), COALESCE(SUM(downloadState = 1), 0) FROM message" 2>/dev/null || echo "0|0")
    read -r rss cpu <<<"$(ps -o rss=,%cpu= -p "$PID" || echo "0 0")"
    threads=$(ps -M -p "$PID" | tail -n +2 | wc -l | tr -d ' ')
    tcp=$( (lsof -nP -a -p "$PID" -iTCP 2>/dev/null || true) | tail -n +2 | wc -l | tr -d ' ')
    echo "$((now - start)),${counts%%|*},${counts##*|},$((rss / 1024)),$cpu,$threads,$tcp"
    sleep "$INTERVAL"
done

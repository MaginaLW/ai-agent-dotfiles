#!/usr/bin/env bash
# Request shutdown of this session without signaling an unverified PID or deleting files.
SESSION_DIR="$1"
STATE_DIR="${SESSION_DIR}/state"

if [[ -z "$SESSION_DIR" ]]; then
  echo '{"error": "Usage: stop-server.sh <session_dir>"}'
  exit 1
fi
if [[ -f "$STATE_DIR/server-stopped" ]]; then
  echo '{"status": "stopped"}'
  exit 0
fi
if [[ ! -f "$STATE_DIR/server-info" ]]; then
  echo '{"status": "not_running"}'
  exit 0
fi

# Never overwrite an existing file, including a symlink.
if [[ ! -e "$STATE_DIR/stop-request" && ! -L "$STATE_DIR/stop-request" ]]; then
  (set -o noclobber; : > "$STATE_DIR/stop-request") 2>/dev/null || {
    echo '{"error": "Could not create stop request"}'
    exit 1
  }
fi
for i in {1..30}; do
  if [[ -f "$STATE_DIR/server-stopped" ]]; then
    echo '{"status": "stopped"}'
    exit 0
  fi
  sleep 0.1
done
echo '{"status": "unconfirmed", "error": "Server did not acknowledge shutdown"}'
exit 1

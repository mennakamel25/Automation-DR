#!/usr/bin/env bash
# Usage: crp-backup full|diff    (systemd timers; both DB nodes run it, only the writable primary acts)
set -euo pipefail
TYPE="${1:?full|diff}"
IS_PRIMARY=$(sudo -u postgres psql -Atqc "SELECT NOT pg_is_in_recovery()" 2>/dev/null || echo f)
if [ "$IS_PRIMARY" != "t" ]; then
  echo "not the primary, skipping $TYPE backup"
  exit 0
fi
sudo -u postgres pgbackrest --stanza=crp --type="$TYPE" backup
sudo -u postgres pgbackrest --stanza=crp check

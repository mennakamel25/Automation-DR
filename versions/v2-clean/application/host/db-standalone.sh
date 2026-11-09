#!/usr/bin/env bash
# Runs on the DRS-recovered database instance in the DR region (called from crp-boot.sh).
# The disk is a crash-consistent copy of a primary-region PostgreSQL node. The Patroni/etcd peers live in the
# failed region, so we start PostgreSQL as a standalone primary and adopt the new failover generation.
set -uo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

DATA=/var/lib/postgresql/data
BIN=/usr/lib/postgresql/15/bin
export AWS_DEFAULT_REGION="${CRP_REGION:?}"

systemctl disable --now patroni etcd 2>/dev/null || true

if sudo -u postgres "$BIN/pg_ctl" -D "$DATA" status >/dev/null 2>&1; then
  log "db-standalone: PostgreSQL already running"
else
  # If the copied node was a standby, make it a primary on startup.
  rm -f "$DATA/standby.signal" "$DATA/recovery.signal"
  sed -i -e '/^primary_conninfo/d' -e '/^primary_slot_name/d' -e '/^recovery_target/d' "$DATA/postgresql.auto.conf" 2>/dev/null || true
  install -d -o postgres -g postgres /var/run/postgresql /var/log/postgresql
  OPTS="-c listen_addresses=* -c port=5432 -c unix_socket_directories=/var/run/postgresql \
        -c max_connections=100 -c max_worker_processes=8 -c max_prepared_transactions=0 -c max_locks_per_transaction=64 \
        -c wal_level=replica -c max_wal_senders=10 -c max_replication_slots=10 -c hot_standby=on -c wal_log_hints=on \
        -c archive_mode=on -c archive_timeout=60 -c archive_command='pgbackrest --stanza=crp archive-push %p'"
  if ! sudo -u postgres "$BIN/pg_ctl" -D "$DATA" -o "$OPTS" -l /var/log/postgresql/standalone.log -w -t 300 start; then
    log "db-standalone: PostgreSQL failed to start; check /var/log/postgresql/standalone.log (fallback: pgBackRest restore)"
    exit 1
  fi
  log "db-standalone: PostgreSQL started"
fi

# Drop replication slots that belonged to the lost peer (they would retain WAL forever).
sudo -u postgres psql -Atqc "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE NOT active" >/dev/null 2>&1 || true

GEN=$(aws ssm get-parameter --name /crp/state/failover_generation --query Parameter.Value --output text 2>/dev/null || echo 1)
sudo -u postgres psql -d crp -Atqc "UPDATE dr_meta SET value='${GEN}' WHERE key='failover_generation'" >/dev/null 2>&1 \
  && log "db-standalone: failover_generation set to ${GEN}"
exit 0

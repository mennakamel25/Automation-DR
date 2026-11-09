#!/usr/bin/env bash
# PostgreSQL 15 + Patroni (HA inside the primary region) + etcd member + pgBackRest (backups to S3).
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

"$CRP_OPT/app/host/install-common.sh"
install_pkgs postgresql-15 postgresql-client-15 pgbackrest python3-dev libpq-dev gcc

# The default cluster is replaced by the one Patroni bootstraps.
systemctl disable --now postgresql 2>/dev/null || true
pg_dropcluster --stop 15 main 2>/dev/null || true

# ---- data disk: the extra EBS volume attached at launch (/dev/sdf). DRS replicates it with the boot disk. ----
MNT=/var/lib/postgresql
find_data_disk() {
  local root
  root=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)
  lsblk -dnpo NAME,TYPE | awk -v r="/dev/${root}" '$2=="disk" && $1!=r {print $1; exit}'
}
DEV=$(find_data_disk)
if [ -n "$DEV" ] && ! mountpoint -q "$MNT"; then
  blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -F -m 0 "$DEV"
  UUID=$(blkid -s UUID -o value "$DEV")
  # mounted by UUID with nofail: the volume id changes after a DRS recovery, the UUID does not
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $MNT ext4 defaults,nofail 0 2" >> /etc/fstab
  mkdir -p "$MNT" && mount "$MNT"
fi
mkdir -p "$MNT/data" && chown -R postgres:postgres "$MNT" && chmod 700 "$MNT/data"

# ---- etcd member ----
"$CRP_OPT/app/host/etcd-setup.sh"

# ---- secrets (AWS Secrets Manager, instance role) ----
IP=$(imds meta-data/local-ipv4)
PG_SUPER=$(aws_secret "$CRP_SECRET_PG_SUPER")
PG_REPL=$(aws_secret "$CRP_SECRET_PG_REPL")
BK_PASS=$(aws_secret "$CRP_SECRET_PGBR_PASS")

# ---- pgBackRest -> S3 bucket in the DR region (Object Lock; authenticated by the instance role) ----
umask 077
mkdir -p /etc/pgbackrest
cat > /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-type=s3
repo1-s3-bucket=${CRP_BACKUP_BUCKET}
repo1-s3-endpoint=s3.${CRP_BACKUP_REGION}.amazonaws.com
repo1-s3-region=${CRP_BACKUP_REGION}
repo1-s3-uri-style=host
repo1-s3-key-type=auto
repo1-path=/pgbackrest
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=${BK_PASS}
repo1-retention-full=7
repo1-retention-diff=14
start-fast=y
compress-type=zst
log-level-console=info

[crp]
pg1-path=${MNT}/data
pg1-port=5432
pg1-socket-path=/var/run/postgresql
pg1-user=postgres
EOF
chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

# ---- Patroni ----
python3 -m venv /opt/patroni
/opt/patroni/bin/pip install -q --upgrade pip
/opt/patroni/bin/pip install -q "patroni[etcd3]" psycopg2-binary

mkdir -p /etc/patroni
cat > /etc/patroni/patroni.yml <<EOF
scope: crp-pg
namespace: /crp/
name: ${CRP_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${IP}:8008

etcd3:
  hosts: ${CRP_IP_PG_A}:2379,${CRP_IP_PG_B}:2379,${CRP_IP_WITNESS}:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        wal_log_hints: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        archive_mode: "on"
        archive_timeout: 60
        archive_command: "pgbackrest --stanza=crp archive-push %p"
  initdb:
    - encoding: UTF8
    - data-checksums
  post_bootstrap: /opt/crp/app/host/pg-post-bootstrap.sh

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${IP}:5432
  data_dir: ${MNT}/data
  bin_dir: /usr/lib/postgresql/15/bin
  pgpass: /var/lib/postgresql/.pgpass
  authentication:
    superuser:   { username: postgres,   password: "${PG_SUPER}" }
    replication: { username: replicator, password: "${PG_REPL}" }
  parameters:
    unix_socket_directories: /var/run/postgresql
  pg_hba:
    - local all postgres peer
    - local all all peer
    - host  replication replicator ${CRP_PRIMARY_VPC_CIDR} scram-sha-256
    - host  all all 127.0.0.1/32 scram-sha-256
    - host  all all ${CRP_PRIMARY_VPC_CIDR} scram-sha-256
    - host  all all ${CRP_DR_VPC_CIDR} scram-sha-256

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
EOF
chown postgres:postgres /etc/patroni/patroni.yml && chmod 600 /etc/patroni/patroni.yml

install -m 644 "$CRP_OPT/app/host/systemd/patroni.service" /etc/systemd/system/patroni.service

# ---- backup timers (run only on the current leader) ----
install -m 755 "$CRP_OPT/app/host/crp-backup.sh" /usr/local/bin/crp-backup
for t in full diff; do
  cat > "/etc/systemd/system/crp-backup-$t.service" <<EOF
[Unit]
Description=pgBackRest $t backup (leader only)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/crp-backup $t
EOF
done
cat > /etc/systemd/system/crp-backup-full.timer <<'EOF'
[Timer]
OnCalendar=*-*-* 02:00:00 UTC
RandomizedDelaySec=300
Persistent=true
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/crp-backup-diff.timer <<'EOF'
[Timer]
OnCalendar=*-*-* 08,14,20:00:00 UTC
RandomizedDelaySec=300
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable patroni.service crp-backup-full.timer crp-backup-diff.timer

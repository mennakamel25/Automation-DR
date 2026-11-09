#!/usr/bin/env bash
# Called by Patroni once, on the first node, right after initdb. $1 = connection URL.
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

APP_PW=$(aws_secret "$CRP_SECRET_DB_APP")
psql "$1" -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE crp_app LOGIN PASSWORD '${APP_PW}';
CREATE DATABASE crp OWNER crp_app;
SQL

# Create the backup stanza so archive_command (archive-push) starts succeeding.
pgbackrest --stanza=crp stanza-create || true

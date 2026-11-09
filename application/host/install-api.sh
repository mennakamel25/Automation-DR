#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

"$CRP_OPT/app/host/install-common.sh"

id -u crp >/dev/null 2>&1 || useradd --system --home /opt/crp --shell /usr/sbin/nologin crp
python3 -m venv /opt/crp/venv
/opt/crp/venv/bin/pip install -q --upgrade pip
/opt/crp/venv/bin/pip install -q -r "$CRP_OPT/app/backend/requirements.txt"

# Database password is written once to a root-only file; DRS copies it with the disk.
DB_PASSWORD=$(aws_secret "$CRP_SECRET_DB_APP")
umask 077
cat > "$CRP_ETC/api.env" <<EOF
DB_NAME=crp
DB_USER=crp_app
DB_PASSWORD=${DB_PASSWORD}
INTERNAL_DOMAIN=${CRP_INTERNAL_DOMAIN}
EOF
chown root:crp "$CRP_ETC/api.env" && chmod 640 "$CRP_ETC/api.env"
echo 1 > "$CRP_ETC/generation"

install -m 644 "$CRP_OPT/app/host/systemd/crp-api.service" /etc/systemd/system/crp-api.service
systemctl daemon-reload
systemctl enable crp-api.service

#!/usr/bin/env bash
# Packages, SSM agent and AWS DRS agent shared by every VM role.
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

install_pkgs ca-certificates curl jq unzip openssl awscli \
  build-essential perl python3 python3-venv wget gawk "linux-headers-$(uname -r)"

# Debian AMIs do not ship the SSM agent. The DR controller uses SSM Run Command to validate recovered instances.
if ! systemctl cat amazon-ssm-agent >/dev/null 2>&1; then
  curl -fsSL -o /tmp/amazon-ssm-agent.deb \
    "https://s3.${CRP_PRIMARY_REGION}.amazonaws.com/amazon-ssm-${CRP_PRIMARY_REGION}/latest/debian_amd64/amazon-ssm-agent.deb"
  dpkg -i /tmp/amazon-ssm-agent.deb
  systemctl enable --now amazon-ssm-agent
fi

"$CRP_OPT/app/host/install-drs-agent.sh" || true

#!/usr/bin/env bash
# Shared helpers for CRP host scripts. Source this file; do not execute it.
# Every instance runs on AWS: in the primary region, or - after an AWS DRS recovery - in the DR region
# from the very same disk image. Scripts therefore ask the instance metadata service where they are.

CRP_ETC=/etc/crp
CRP_OPT=/opt/crp
export CRP_OPT

log() { logger -t crp "$*"; echo "[crp] $*" >&2; }

load_node_env() {
  # shellcheck disable=SC1091
  [ -f "$CRP_ETC/node.env" ] && set -a && . "$CRP_ETC/node.env" && set +a
  [ -f "$CRP_ETC/cloud.env" ] && set -a && . "$CRP_ETC/cloud.env" && set +a
  return 0
}

imds() { # AWS IMDSv2 GET:  imds meta-data/placement/region
  local t
  t=$(curl -fsS -m 3 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' http://169.254.169.254/latest/api/token)
  curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/$1"
}

# aws_secret <secret-id>   Secrets Manager; secrets are replicated to the DR region under the same name,
# so the region the instance runs in is always the right one (first boot: crp-boot has not run yet).
aws_secret() {
  aws secretsmanager get-secret-value --region "${CRP_REGION:-${CRP_PRIMARY_REGION:?}}" \
    --secret-id "$1" --query SecretString --output text
}

install_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "$@"
}

mark_done() { mkdir -p /var/lib/crp && touch "/var/lib/crp/$1.done"; }
is_done() { [ -f "/var/lib/crp/$1.done" ]; }

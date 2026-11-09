#!/usr/bin/env bash
# etcd witness in the third zone: holds quorum only, stores no application data.
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env
install_pkgs curl jq
"$CRP_OPT/app/host/etcd-setup.sh"

#!/usr/bin/env bash
# etcd witness in the third zone: holds quorum only, stores no application data.
set -euo pipefail

. /opt/crp/app/host/lib.sh
load_node_env

"$CRP_OPT/app/host/install-common.sh"

install_pkgs curl jq
"$CRP_OPT/app/host/etcd-setup.sh"

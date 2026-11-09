#!/usr/bin/env bash
# Configures one member of the 3-node etcd cluster (pg-a, pg-b, witness) used by Patroni.
# The witness lives in a third AZ so quorum survives the loss of one AZ.
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

IP=$(imds meta-data/local-ipv4)
install_pkgs etcd-server etcd-client

cat > /etc/default/etcd <<EOF
ETCD_NAME="${CRP_NAME}"
ETCD_DATA_DIR="/var/lib/etcd/${CRP_NAME}.etcd"
ETCD_LISTEN_PEER_URLS="http://${IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${IP}:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${IP}:2379"
ETCD_INITIAL_CLUSTER="pg-a=http://${CRP_IP_PG_A}:2380,pg-b=http://${CRP_IP_PG_B}:2380,witness=http://${CRP_IP_WITNESS}:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="crp-etcd"
EOF
systemctl enable etcd
systemctl restart etcd

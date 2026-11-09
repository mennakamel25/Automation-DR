#!/usr/bin/env bash
# Run once by the EC2 user data (templates/startup.sh.tftpl) after the bundle is unpacked:
#   * installs the role (web / api / db / witness)
#   * registers crp-boot.service, which runs on EVERY boot - also on the instances AWS DRS recovers
#     in the DR region (user data does not run again there; systemd units on the disk do).
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

if ! is_done role-installed; then
  "/opt/crp/app/host/install-${CRP_ROLE}.sh"
  mark_done role-installed
fi

install -m 644 /opt/crp/app/host/systemd/crp-boot.service /etc/systemd/system/crp-boot.service
systemctl daemon-reload
systemctl enable crp-boot.service
systemctl start crp-boot.service || true

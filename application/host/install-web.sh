#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. /opt/crp/app/host/lib.sh
load_node_env

"$CRP_OPT/app/host/install-common.sh"
install_pkgs nginx

mkdir -p /var/www/crp "$CRP_ETC/tls" "$CRP_OPT/nginx"
cp -r "$CRP_OPT/app/frontend/." /var/www/crp/
cp "$CRP_OPT/app/nginx/crp.conf.tmpl" "$CRP_OPT/nginx/crp.conf.tmpl"
rm -f /etc/nginx/sites-enabled/default

# The public certificate is the ALB's ACM certificate. Between the ALB and Nginx the traffic is still
# TLS, with this self-signed certificate (an ALB does not validate target certificates).
if [ ! -f "$CRP_ETC/tls/fullchain.pem" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=${CRP_DOMAIN}" \
    -keyout "$CRP_ETC/tls/privkey.pem" -out "$CRP_ETC/tls/fullchain.pem" 2>/dev/null
  chmod 600 "$CRP_ETC/tls/privkey.pem"
fi

systemctl enable nginx

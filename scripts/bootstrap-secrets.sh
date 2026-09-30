#!/usr/bin/env bash
#
# One-time creation of the Secrets the chart references (existingSecret).
# Values are never committed; this script reads them from the environment.
#
#   SIP_SECRET          shared gateway/kamailio SIP registration password
#   TURN_USER, TURN_PASS credentials for the coturn at turn.example.org
#   MYSQL_ROOT_PASSWORD                   kamailio DB root password
#                                         (the kamailio user is created by
#                                         kamailioRun.py, as upstream)
#   POSTGRES_USER, POSTGRES_PASSWORD      homer DB credentials
#
# Usage:
#   set -a; . ../secrets.env; set +a   # file lives one level above the repo
#   ./scripts/bootstrap-secrets.sh

set -euo pipefail

NS="${SIPMEDIAGW_NAMESPACE:-sipmediagw}"
GW_PREFIX="${GW_NAME_PREFIX:-mediagw}"

require() {
  if [ -z "${!1:-}" ]; then
    echo "ERROR: \$${1} is not set" >&2
    exit 1
  fi
}

require SIP_SECRET
require TURN_USER
require TURN_PASS
require MYSQL_ROOT_PASSWORD
require POSTGRES_USER
require POSTGRES_PASSWORD

kubectl create namespace "$NS" 2>/dev/null || true

kubectl -n "$NS" create secret generic sipmediagw-sip-secret \
  --from-literal=SIP_SECRET="$SIP_SECRET" \
  --from-literal=GW_NAME_PREFIX="$GW_PREFIX" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic sipmediagw-turn-secret \
  --from-literal=TURN_USER="$TURN_USER" \
  --from-literal=TURN_PASS="$TURN_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic sipmediagw-mysql-secret \
  --from-literal=MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic sipmediagw-postgres-secret \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secrets applied in namespace $NS."

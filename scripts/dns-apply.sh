#!/usr/bin/env bash
#
# Create or update the demo's DNS records at DNSimple from the cluster's
# LoadBalancer addresses (infra/dns). Idempotent: run it whenever a load
# balancer appears or changes. scripts/kubeadm-up.sh calls it at the end when
# the DNSimple credentials are present.
#
# Prerequisites:
#   - The dnsimple CLI logged in (`dnsimple auth login`), the way doctl is for
#     DigitalOcean; or DNSIMPLE_TOKEN (+ DNSIMPLE_ACCOUNT) in the environment.
#     See scripts/lib/dnsimple-token.sh.
#   - infra/kubeconfig from scripts/kubeadm-up.sh (or KUBECONFIG set).
#
# Usage:
#   ./scripts/dns-apply.sh
#   WAIT_SECONDS=0 ./scripts/dns-apply.sh    # don't wait for missing addresses

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DNS_DIR="$REPO_ROOT/infra/dns"
KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/infra/kubeconfig}"
export KUBECONFIG
# How long to wait for a LoadBalancer Service that exists but has no address.
WAIT_SECONDS="${WAIT_SECONDS:-300}"
# namespace/name of the Services infra/dns/variables.tf publishes.
SERVICES="teleport/teleport-cluster traefik/traefik"

log() { printf '\n==> %s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }
# shellcheck source=lib/dnsimple-token.sh
. "$REPO_ROOT/scripts/lib/dnsimple-token.sh"

# --- preflight -------------------------------------------------------------
for bin in terraform kubectl curl; do
  command -v "$bin" >/dev/null 2>&1 || err "$bin not found on PATH."
done
resolve_dnsimple_token || { dnsimple_token_help; exit 1; }
[ -f "$KUBECONFIG" ] || err "kubeconfig $KUBECONFIG not found; run scripts/kubeadm-up.sh first."
kubectl get --raw /readyz --request-timeout=10s >/dev/null 2>&1 || err "cluster not reachable with $KUBECONFIG."

# --- wait for addresses ----------------------------------------------------
# A Service that is absent (its app not deployed yet) is skipped: the module
# reports it under `pending`. One that exists is given WAIT_SECONDS to get an
# address from the cloud controller manager.
for svc in $SERVICES; do
  ns="${svc%/*}"; name="${svc#*/}"
  if ! kubectl -n "$ns" get svc "$name" >/dev/null 2>&1; then
    echo "note: ${ns}/${name} does not exist yet; its records will be pending."
    continue
  fi
  waited=0
  until [ -n "$(kubectl -n "$ns" get svc "$name" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)" ]; do
    [ "$waited" -lt "$WAIT_SECONDS" ] || { echo "warning: ${ns}/${name} still has no address after ${WAIT_SECONDS}s; its records will be pending."; break; }
    [ "$waited" -eq 0 ] && echo "waiting for ${ns}/${name} to get an address..."
    sleep 10; waited=$((waited + 10))
  done
done

# --- apply -----------------------------------------------------------------
log "Terraform: DNS records at DNSimple"
terraform -chdir="$DNS_DIR" init -input=false >/dev/null
terraform -chdir="$DNS_DIR" apply -input=false -auto-approve -var "kubeconfig_path=${KUBECONFIG}"

echo
terraform -chdir="$DNS_DIR" output records
pending="$(terraform -chdir="$DNS_DIR" output -json pending)"
if [ "$pending" != "[]" ]; then
  echo "Pending (re-run this script once the load balancer exists):"
  echo "$pending" | tr -d '[]"' | tr ',' '\n' | sed 's/^ */  /'
fi

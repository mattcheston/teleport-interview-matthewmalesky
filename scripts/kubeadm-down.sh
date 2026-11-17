#!/usr/bin/env bash
#
# Tear down the DigitalOcean kubeadm cluster built by scripts/kubeadm-up.sh.
#
# Order matters. The DNS records (infra/dns) read their addresses from the
# cluster, so they go first, while it is still reachable. Things the cluster
# created in DigitalOcean for itself (load balancers via the cloud controller
# manager, the Teleport volume via the CSI driver) must be deleted through
# Kubernetes next. Otherwise Terraform removes the droplets and leaves them
# behind, still billing.
#
# Usage:
#   ./scripts/kubeadm-down.sh
#   With the dnsimple CLI logged in (see scripts/lib/dnsimple-token.sh) the DNS
#   records are removed too.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"
DNS_DIR="$REPO_ROOT/infra/dns"
KUBECONFIG_OUT="$REPO_ROOT/infra/kubeconfig"
# Teardown needs cluster-admin (Services and PVCs in every namespace, kube-system).
KUBECONFIG_ADMIN="$REPO_ROOT/infra/kubeconfig-admin"
[ -f "$KUBECONFIG_ADMIN" ] || KUBECONFIG_ADMIN="$KUBECONFIG_OUT"   # clusters built before the deployer identity existed
KNOWN_HOSTS="$REPO_ROOT/infra/known_hosts"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
CLUSTER_NAME="${CLUSTER_NAME:-teleport-demo}"

log() { printf '\n==> %s\n' "$*"; }
. "$REPO_ROOT/scripts/lib/dnsimple-token.sh"

if [ -z "${DIGITALOCEAN_TOKEN:-}" ]; then
  DIGITALOCEAN_TOKEN="$(doctl auth token)"
fi
export DIGITALOCEAN_TOKEN
# Required by the module but irrelevant to a destroy.
export TF_VAR_admin_cidrs="${TF_VAR_admin_cidrs:-[\"127.0.0.1/32\"]}"
export TF_VAR_cluster_name="$CLUSTER_NAME"

if [ -f "$KUBECONFIG_ADMIN" ] && KUBECONFIG="$KUBECONFIG_ADMIN" kubectl get --raw /readyz --request-timeout=10s >/dev/null 2>&1; then
  export KUBECONFIG="$KUBECONFIG_ADMIN"

  if [ -f "$DNS_DIR/terraform.tfstate" ]; then
    if resolve_dnsimple_token; then
      log "Removing the DNS records (infra/dns)"
      terraform -chdir="$DNS_DIR" init -input=false >/dev/null
      terraform -chdir="$DNS_DIR" destroy -input=false -auto-approve -var "kubeconfig_path=${KUBECONFIG_ADMIN}" \
        || echo "warning: DNS destroy failed; delete the records at DNSimple by hand."
    else
      echo "warning: no DNSimple login (see scripts/lib/dnsimple-token.sh); the DNS records in infra/dns are left in place (and in state)."
    fi
  fi

  log "Deleting Argo CD Applications (cascades to everything they manage)"
  kubectl -n "$ARGOCD_NS" delete applications --all --wait --timeout=300s 2>/dev/null || true

  log "Deleting any remaining LoadBalancer Services (DigitalOcean load balancers)"
  kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
    | while read -r ns name; do
        [ -n "${name:-}" ] || continue
        kubectl -n "$ns" delete svc "$name" --wait --timeout=180s || true
      done

  log "Deleting PersistentVolumeClaims (DigitalOcean volumes)"
  kubectl delete pvc --all --all-namespaces --wait --timeout=180s || true
  for i in $(seq 1 24); do
    [ -z "$(kubectl get pv -o name 2>/dev/null)" ] && break
    sleep 5
  done
  if [ -n "$(kubectl get pv -o name 2>/dev/null)" ]; then
    echo "warning: PersistentVolumes still present; check 'doctl compute volume list' afterwards."
  fi

  log "Stopping the cloud controller manager (it would otherwise re-create its firewall)"
  kubectl -n kube-system delete deployment digitalocean-cloud-controller-manager --ignore-not-found --wait
else
  echo "Cluster not reachable; skipping in-cluster cleanup."
  echo "Afterwards check for leftovers: doctl compute load-balancer list; doctl compute volume list"
fi

log "Deleting the CCM-managed firewall (not in Terraform state)"
doctl compute firewall list --format ID,Name --no-header \
  | awk -v n="${CLUSTER_NAME}-public-access" '$2 == n { print $1 }' \
  | while read -r id; do doctl compute firewall delete "$id" --force; done

log "Terraform destroy"
terraform -chdir="$TF_DIR" init -input=false >/dev/null
terraform -chdir="$TF_DIR" destroy -input=false -auto-approve
rm -f "$KUBECONFIG_OUT" "$REPO_ROOT/infra/kubeconfig-admin" "$KNOWN_HOSTS"

echo
echo "Done."

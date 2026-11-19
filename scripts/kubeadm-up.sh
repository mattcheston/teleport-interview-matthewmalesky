#!/usr/bin/env bash
#
# Build a kubeadm cluster on DigitalOcean (1 control plane + 2 workers) and
# install everything that has to exist before Argo CD can take over:
#
#   terraform -> kubeadm init / join -> Cilium -> DigitalOcean CCM + CSI -> Argo CD
#
# Safe to re-run: every step checks whether it has already happened.
#
# Prerequisites:
#   - terraform, kubectl, helm, ssh, curl on PATH
#   - doctl authenticated (or DIGITALOCEAN_TOKEN set)
#   - the private half of the SSH key named in infra/terraform/variables.tf
#     usable without a prompt (ssh-add it if it has a passphrase)
#
# Usage:
#   ./scripts/kubeadm-up.sh
#   ADMIN_CIDR=203.0.113.0/24 ./scripts/kubeadm-up.sh   # who may reach 22/6443; default is your current IP
#   With the dnsimple CLI logged in (see scripts/lib/dnsimple-token.sh) the DNS
#   records are created too, via scripts/dns-apply.sh.
#   # Any value not set in the environment falls back to the defaults below.
#
# Afterwards:
#   export KUBECONFIG=$PWD/infra/kubeconfig          # user "deployer" (scoped); infra/kubeconfig-admin is cluster-admin
#
# Tear down:
#   ./scripts/kubeadm-down.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"
KUBECONFIG_OUT="$REPO_ROOT/infra/kubeconfig"          # user "deployer": Argo apps + read-only (scripts/kubeconfig-deployer.sh)
KUBECONFIG_ADMIN="$REPO_ROOT/infra/kubeconfig-admin"  # kubeadm's cluster-admin: bootstrap, teardown, break-glass
KNOWN_HOSTS="$REPO_ROOT/infra/known_hosts"

CLUSTER_NAME="${CLUSTER_NAME:-teleport-demo}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.5}"
DO_CCM_VERSION="${DO_CCM_VERSION:-v0.1.73}"
DO_CSI_VERSION="${DO_CSI_VERSION:-v4.22.0}"
# Git ref in argoproj/argo-cd to install from (a tag like v3.6.2, or "stable").
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.6.2}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

err() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

# --- preflight -------------------------------------------------------------
for bin in terraform kubectl helm ssh curl; do
  command -v "$bin" >/dev/null 2>&1 || err "$bin not found on PATH."
done
if [ -z "${DIGITALOCEAN_TOKEN:-}" ]; then
  command -v doctl >/dev/null 2>&1 || err "set DIGITALOCEAN_TOKEN or install and authenticate doctl."
  DIGITALOCEAN_TOKEN="$(doctl auth token)" || err "doctl auth token failed; run 'doctl auth init'."
fi
export DIGITALOCEAN_TOKEN
ADMIN_CIDR="${ADMIN_CIDR:-$(curl -4 -fsS https://api.ipify.org)/32}"
export TF_VAR_admin_cidrs="[\"${ADMIN_CIDR}\"]"
export TF_VAR_cluster_name="$CLUSTER_NAME"

# --- 1. infrastructure -----------------------------------------------------
log "Terraform: VPC, droplets, firewall (SSH and API access from ${ADMIN_CIDR})"
terraform -chdir="$TF_DIR" init -input=false >/dev/null
terraform -chdir="$TF_DIR" apply -input=false -auto-approve

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
CP_PUBLIC="$(tf_out control_plane_public_ip)"
CP_PRIVATE="$(tf_out control_plane_private_ip)"
WORKERS="$(tf_out worker_public_ips)"

# --- ssh helpers -----------------------------------------------------------
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${KNOWN_HOSTS}"
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR)
# on_node <ip> <command...>; stdin is forwarded.
on_node() { ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

wait_for_node() {
  local ip=$1 i
  for i in $(seq 1 90); do   # up to 15 minutes
    if on_node "$ip" 'test -f /var/lib/kubeadm-node-ready' 2>/dev/null; then
      echo "  ${ip}: ready"
      return 0
    fi
    if on_node "$ip" 'cloud-init status 2>/dev/null | grep -q error' 2>/dev/null; then
      on_node "$ip" 'tail -n 40 /var/log/cloud-init-output.log' || true
      err "cloud-init failed on ${ip} (log tail above)."
    fi
    sleep 10
  done
  err "timed out waiting for cloud-init on ${ip}."
}

log "Waiting for cloud-init (containerd, kubeadm, kubelet) on every node"
for ip in "$CP_PUBLIC" $WORKERS; do wait_for_node "$ip"; done

# --- 2. control plane ------------------------------------------------------
if on_node "$CP_PUBLIC" 'test -f /etc/kubernetes/admin.conf'; then
  log "Control plane already initialised; skipping kubeadm init"
else
  K8S_VERSION="$(on_node "$CP_PUBLIC" 'kubeadm version -o short')"
  log "kubeadm init ${K8S_VERSION} on ${CP_PUBLIC}"
  # kubelet flags (--cloud-provider=external, --node-ip) come from
  # /etc/default/kubelet, written by cloud-init on every node.
  on_node "$CP_PUBLIC" 'cat > /root/kubeadm-config.yaml' <<KUBEADM
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${CP_PRIVATE}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
clusterName: ${CLUSTER_NAME}
# Nodes talk to the API server over the VPC. The public IP is in the
# certificate so the same kubeconfig works from outside.
controlPlaneEndpoint: ${CP_PRIVATE}:6443
networking:
  podSubnet: ${POD_CIDR}
apiServer:
  certSANs:
    - ${CP_PUBLIC}
    - ${CP_PRIVATE}
KUBEADM
  on_node "$CP_PUBLIC" 'kubeadm init --config /root/kubeadm-config.yaml'
fi

log "Writing the admin kubeconfig to ${KUBECONFIG_ADMIN}"
on_node "$CP_PUBLIC" 'cat /etc/kubernetes/admin.conf' > "$KUBECONFIG_ADMIN"
chmod 600 "$KUBECONFIG_ADMIN"
export KUBECONFIG="$KUBECONFIG_ADMIN"
kubectl config set-cluster "$CLUSTER_NAME" --server="https://${CP_PUBLIC}:6443" >/dev/null
kubectl get --raw /readyz >/dev/null || err "API server not reachable at ${CP_PUBLIC}:6443."

# --- 3. workers ------------------------------------------------------------
log "Joining workers"
JOIN_CMD=""
for ip in $WORKERS; do
  if on_node "$ip" 'test -f /etc/kubernetes/kubelet.conf'; then
    echo "  ${ip}: already joined"
    continue
  fi
  [ -n "$JOIN_CMD" ] || JOIN_CMD="$(on_node "$CP_PUBLIC" 'kubeadm token create --ttl 1h --print-join-command')"
  echo "  ${ip}: kubeadm join"
  on_node "$ip" "$JOIN_CMD"
done

# --- 4. CNI ----------------------------------------------------------------
# Has to come before Argo CD: nothing gets a pod IP until the CNI is up.
log "Cilium ${CILIUM_VERSION}"
helm upgrade --install cilium cilium --repo https://helm.cilium.io --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set k8s.requireIPv4PodCIDR=true \
  --set operator.replicas=1
kubectl -n kube-system rollout status ds/cilium --timeout=300s

# --- 5. DigitalOcean integration ------------------------------------------
# CCM: LoadBalancer Services and node lifecycle. CSI: a default StorageClass.
# Both read the API token from the same Secret.
log "DigitalOcean cloud controller manager ${DO_CCM_VERSION} and CSI driver ${DO_CSI_VERSION}"
token_file="$(mktemp)"
trap 'rm -f "$token_file"' EXIT
printf '%s' "$DIGITALOCEAN_TOKEN" > "$token_file"
kubectl -n kube-system create secret generic digitalocean \
  --from-file=access-token="$token_file" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$token_file"

kubectl apply -f "https://raw.githubusercontent.com/digitalocean/digitalocean-cloud-controller-manager/master/releases/digitalocean-cloud-controller-manager/${DO_CCM_VERSION}.yml"
# Two things the upstream manifest cannot know. The VPC the nodes live in:
# without it the CCM builds load balancers in the account default VPC and
# DigitalOcean refuses to attach our droplets. And a firewall it may manage:
# for every LoadBalancer Service it opens the service ports and the
# health-check port on the workers, the latter only from that load balancer.
kubectl -n kube-system set env deployment/digitalocean-cloud-controller-manager \
  DO_CLUSTER_VPC_ID="$(tf_out vpc_id)" \
  PUBLIC_ACCESS_FIREWALL_NAME="${CLUSTER_NAME}-public-access" \
  PUBLIC_ACCESS_FIREWALL_TAGS="$(tf_out worker_tag)"
CSI_BASE="https://raw.githubusercontent.com/digitalocean/csi-digitalocean/master/deploy/kubernetes/releases/csi-digitalocean-${DO_CSI_VERSION}"
kubectl apply -f "${CSI_BASE}/crds.yaml"
kubectl apply -f "${CSI_BASE}/driver.yaml"
kubectl apply -f "${CSI_BASE}/snapshot-controller.yaml"

log "Waiting for the CCM to initialise the nodes"
tainted=1
for i in $(seq 1 60); do
  tainted="$(kubectl get nodes -o jsonpath='{range .items[*]}{range .spec.taints[*]}{.key}{"\n"}{end}{end}' \
    | grep -c 'node.cloudprovider.kubernetes.io/uninitialized' || true)"
  [ "$tainted" = "0" ] && break
  sleep 5
done
[ "$tainted" = "0" ] || err "nodes still carry the uninitialized taint; see: kubectl -n kube-system logs deploy/digitalocean-cloud-controller-manager"
kubectl wait --for=condition=Ready node --all --timeout=300s

# --- 6. Argo CD ------------------------------------------------------------
log "Argo CD ${ARGOCD_VERSION} into namespace ${ARGOCD_NS}"
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$ARGOCD_NS" --server-side --force-conflicts -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=300s
kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n "$ARGOCD_NS" rollout status statefulset/argocd-application-controller --timeout=300s

# --- 7. deployer identity ---------------------------------------------------
# Day-to-day access is a scoped Kubernetes user with an X.509 client
# certificate signed by the cluster, not kubeadm's cluster-admin. Its boundary
# (RBAC and admission policy in infra/rbac/, Argo CD projects in infra/argocd/)
# is applied by the same script, which is why this step follows the Argo CD
# install. The admin kubeconfig stays for bootstrap and teardown.
ADMIN_KUBECONFIG="$KUBECONFIG_ADMIN" OUT="$KUBECONFIG_OUT" "$REPO_ROOT/scripts/kubeconfig-deployer.sh"

# --- 8. app-of-apps --------------------------------------------------------
# Applied as the deployer: this is the identity that will manage the apps.
if grep -q CHANGEME "$REPO_ROOT/bootstrap/root-app.yaml"; then
  bootstrap_note="bootstrap/ still has the CHANGEME repoURL. Replace it, push, then: kubectl apply -f bootstrap/"
else
  log "Applying bootstrap/ (root Application) as the deployer"
  KUBECONFIG="$KUBECONFIG_OUT" kubectl apply -f "$REPO_ROOT/bootstrap/"
  bootstrap_note="root Application applied. Watch it: kubectl -n ${ARGOCD_NS} get applications -w"
fi

# --- 9. DNS ------------------------------------------------------------------
# Records at DNSimple, derived from the LoadBalancer addresses Argo creates.
# Only when the credentials are present; otherwise it is a separate step.
# Runs as the deployer too: reading Services is all it needs.
. "$REPO_ROOT/scripts/lib/dnsimple-token.sh"
if resolve_dnsimple_token && [ -z "${bootstrap_note##root Application applied*}" ]; then
  log "DNS: waiting for the load balancers, then scripts/dns-apply.sh"
  KUBECONFIG="$KUBECONFIG_OUT" "$REPO_ROOT/scripts/dns-apply.sh" || echo "warning: DNS apply failed; re-run scripts/dns-apply.sh later."
  dns_note="DNS records applied (see above)."
else
  dns_note="DNS: once Teleport and Traefik have addresses, run ./scripts/dns-apply.sh (needs 'dnsimple auth login' first)"
fi

# --- summary ---------------------------------------------------------------
echo
echo "Cluster is up."
kubectl get nodes -o wide
echo
echo "  kubeconfig:   export KUBECONFIG=${KUBECONFIG_OUT}     (user deployer: Argo apps + read-only; renew: scripts/kubeconfig-deployer.sh)"
echo "  admin:        ${KUBECONFIG_ADMIN}     (kubeadm cluster-admin: tctl, teardown, break-glass)"
echo "  ssh:          ssh root@${CP_PUBLIC}"
echo "  Argo CD UI:   kubectl -n ${ARGOCD_NS} port-forward svc/argocd-server 8080:443  ->  https://localhost:8080"
echo "  Argo user:    admin"
printf '  Argo pass:    '
kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null \
  | base64 -d || printf '(initial admin secret already removed)'
echo
echo
echo "  ${bootstrap_note}"
echo "  ${dns_note}"

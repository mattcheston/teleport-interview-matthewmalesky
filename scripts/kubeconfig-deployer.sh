#!/usr/bin/env bash
#
# Issue a client certificate for a Kubernetes user through the cluster's
# CertificateSigningRequest API and write a kubeconfig for it. The user belongs
# to the `deployers` group, whose permissions are infra/rbac/deployer.yaml:
# manage Argo CD Applications, read everything else.
#
# This is what infra/kubeconfig is. scripts/kubeadm-up.sh runs this once the
# control plane is up; run it again to renew the certificate (every run issues
# a new one) or to issue one for someone else.
#
# Needs a kubeconfig with admin rights on the target cluster to apply the RBAC
# and approve the request (default: infra/kubeconfig-admin from
# scripts/kubeadm-up.sh; on any other cluster, point ADMIN_KUBECONFIG at your
# own and its current context is used), and openssl.
#
# Usage:
#   ./scripts/kubeconfig-deployer.sh                 # user "deployer", 90 days, -> infra/kubeconfig
#   ADMIN_KUBECONFIG=~/.kube/config ./scripts/kubeconfig-deployer.sh
#   USER_NAME=ci CERT_DAYS=30 OUT=infra/kubeconfig-ci ./scripts/kubeconfig-deployer.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_KUBECONFIG="${ADMIN_KUBECONFIG:-$REPO_ROOT/infra/kubeconfig-admin}"
OUT="${OUT:-$REPO_ROOT/infra/kubeconfig}"
USER_NAME="${USER_NAME:-deployer}"
GROUP="${GROUP:-deployers}"
CERT_DAYS="${CERT_DAYS:-90}"   # the controller manager caps this at its --cluster-signing-duration (default 1 year)

log() { printf '\n==> %s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

for bin in kubectl openssl; do command -v "$bin" >/dev/null 2>&1 || err "$bin not found on PATH."; done
[ -f "$ADMIN_KUBECONFIG" ] || err "admin kubeconfig $ADMIN_KUBECONFIG not found; run scripts/kubeadm-up.sh first."
export KUBECONFIG="$ADMIN_KUBECONFIG"
kubectl get --raw /readyz --request-timeout=10s >/dev/null 2>&1 || err "cluster not reachable with $ADMIN_KUBECONFIG."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- RBAC for the group -----------------------------------------------------
log "RBAC for group '${GROUP}' (infra/rbac/deployer.yaml)"
kubectl apply -f "$REPO_ROOT/infra/rbac/deployer.yaml"

# --- key + CSR, signed by the cluster ---------------------------------------
# The certificate's CN becomes the username and O the group: that is how the
# API server maps X.509 client certificates to identities.
log "Issuing a ${CERT_DAYS}-day client certificate for user '${USER_NAME}' (group '${GROUP}')"
openssl ecparam -name prime256v1 -genkey -noout -out "$work/key.pem"
openssl req -new -key "$work/key.pem" -subj "/CN=${USER_NAME}/O=${GROUP}" -out "$work/csr.pem"

csr_name="${USER_NAME}-$(date -u +%Y%m%d%H%M%S)"
kubectl apply -f - <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${csr_name}
spec:
  request: $(base64 < "$work/csr.pem" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $((CERT_DAYS * 86400))
  usages: ["client auth"]
YAML
kubectl certificate approve "$csr_name" >/dev/null
for i in $(seq 1 30); do
  kubectl get csr "$csr_name" -o jsonpath='{.status.certificate}' | base64 -d > "$work/cert.pem" 2>/dev/null
  [ -s "$work/cert.pem" ] && break
  sleep 1
done
[ -s "$work/cert.pem" ] || err "the signer did not return a certificate for CSR ${csr_name}."
# Signed; the CSR object has served its purpose. Older ones are pruned too.
kubectl get csr -o name | grep "^certificatesigningrequest.certificates.k8s.io/${USER_NAME}-" | xargs -r kubectl delete >/dev/null

# --- kubeconfig --------------------------------------------------------------
# Cluster address and CA are copied from the admin kubeconfig's current context
# (--minify); --flatten embeds a CA that is referenced as a file.
cluster="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
kubectl config view --minify --raw --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$work/ca.crt"
[ -s "$work/ca.crt" ] || err "could not read the cluster CA from ${ADMIN_KUBECONFIG}'s current context."

rm -f "$OUT"
kubectl config --kubeconfig="$OUT" set-cluster "$cluster" --server="$server" --certificate-authority="$work/ca.crt" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$OUT" set-credentials "$USER_NAME" --client-certificate="$work/cert.pem" --client-key="$work/key.pem" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$OUT" set-context "${USER_NAME}@${cluster}" --cluster="$cluster" --user="$USER_NAME" >/dev/null
kubectl config --kubeconfig="$OUT" use-context "${USER_NAME}@${cluster}" >/dev/null
chmod 600 "$OUT"

# --- prove it ----------------------------------------------------------------
log "Checking the new identity"
KUBECONFIG="$OUT" kubectl auth whoami
printf 'can create Applications in argocd: %s\n' "$(KUBECONFIG="$OUT" kubectl auth can-i create applications.argoproj.io -n argocd)"
printf 'can read pods everywhere:          %s\n' "$(KUBECONFIG="$OUT" kubectl auth can-i list pods --all-namespaces)"
printf 'can read secrets in teleport:      %s\n' "$(KUBECONFIG="$OUT" kubectl auth can-i get secrets -n teleport)"
printf 'can delete nodes:                  %s\n' "$(KUBECONFIG="$OUT" kubectl auth can-i delete nodes 2>/dev/null)"
echo
echo "Wrote ${OUT} (user ${USER_NAME}, certificate valid until $(openssl x509 -noout -enddate -in "$work/cert.pem" | cut -d= -f2))."

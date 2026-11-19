#!/usr/bin/env bash
#
# Issue a client certificate for a Kubernetes user through the cluster's
# CertificateSigningRequest API and write a kubeconfig for it. The user belongs
# to the `deployers` group, whose boundary this script applies as well:
#   infra/rbac/deployer.yaml         RBAC: manage Argo CD Applications, read everything else
#   infra/rbac/deployer-policy.yaml  admission policy: those Applications may only render this repo at main
#   infra/argocd/projects.yaml       Argo CD projects: where they may deploy, and which kinds
#
# This is what infra/kubeconfig is. scripts/kubeadm-up.sh runs this once the
# control plane is up; run it again to renew the certificate (every run issues
# a new one) or to issue one for someone else.
#
# Needs a kubeconfig with admin rights on the target cluster to apply all that
# and approve the request (default: infra/kubeconfig-admin from
# scripts/kubeadm-up.sh; on any other cluster, point ADMIN_KUBECONFIG at your
# own and its current context is used), openssl, Argo CD already installed (the
# projects are its objects) and Kubernetes 1.30 or newer (ValidatingAdmissionPolicy).
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
GROUP="${GROUP:-deployers}"    # the RBAC bindings and the admission policy are keyed on this name
CERT_DAYS="${CERT_DAYS:-90}"   # the controller manager caps this at its --cluster-signing-duration (default 1 year)

log() { printf '\n==> %s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

for bin in kubectl openssl; do command -v "$bin" >/dev/null 2>&1 || err "$bin not found on PATH."; done
[ -f "$ADMIN_KUBECONFIG" ] || err "admin kubeconfig $ADMIN_KUBECONFIG not found; run scripts/kubeadm-up.sh first."
export KUBECONFIG="$ADMIN_KUBECONFIG"
kubectl get --raw /readyz --request-timeout=10s >/dev/null 2>&1 || err "cluster not reachable with $ADMIN_KUBECONFIG."
kubectl get crd appprojects.argoproj.io >/dev/null 2>&1 || err "Argo CD is not installed (no AppProject CRD); install it first."
kubectl api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null \
  | grep -qx validatingadmissionpolicies.admissionregistration.k8s.io \
  || err "ValidatingAdmissionPolicy is required (Kubernetes 1.30 or newer)."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- the group's boundary: RBAC, admission policy, Argo CD projects ----------
log "RBAC and admission policy for group '${GROUP}' (infra/rbac/)"
kubectl apply -f "$REPO_ROOT/infra/rbac/deployer.yaml"
kubectl apply -f "$REPO_ROOT/infra/rbac/deployer-policy.yaml"

# Server-side, so the empty lists in our locked `default` project replace the
# wide-open ones Argo CD wrote when it created that project.
log "Argo CD projects (infra/argocd/projects.yaml)"
kubectl apply --server-side --force-conflicts -f "$REPO_ROOT/infra/argocd/projects.yaml"
repos="$(kubectl -n argocd get appproject default -o jsonpath='{.spec.sourceRepos}')"
case "$repos" in ""|"[]") ;; *) err "AppProject default still permits sources: ${repos}" ;; esac

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
printf 'can create AppProjects in argocd:  %s\n' "$(KUBECONFIG="$OUT" kubectl auth can-i create appprojects.argoproj.io -n argocd 2>/dev/null)"
printf 'can read the Argo CD admin secret: %s\n' "$(KUBECONFIG="$OUT" kubectl auth can-i get secret/argocd-initial-admin-secret -n argocd 2>/dev/null)"
# The admission policy, exercised with a server-side dry run: an Application
# that points anywhere but this repository must be refused.
probe="$(KUBECONFIG="$OUT" kubectl apply --dry-run=server -f - 2>&1 <<YAML || true
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: deployer-policy-probe
  namespace: argocd
spec:
  project: apps
  source:
    repoURL: https://example.com/not-this-repo.git
    targetRevision: main
    path: nginx
  destination:
    server: https://kubernetes.default.svc
    namespace: nginx
YAML
)"
case "$probe" in
  *ValidatingAdmissionPolicy*) probe_result=yes ;;
  *) probe_result="NO: ${probe}" ;;
esac
printf 'policy rejects a foreign repo:     %s\n' "$probe_result"
echo
echo "Wrote ${OUT} (user ${USER_NAME}, certificate valid until $(openssl x509 -noout -enddate -in "$work/cert.pem" | cut -d= -f2))."

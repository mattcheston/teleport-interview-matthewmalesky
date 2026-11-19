# teleport-interview-matthewmalesky

A demo for the Teleport hiring team. Argo CD deploys **Teleport Community Edition**,
**cert-manager**, **Traefik** and an **nginx** landing page with my resume from this
repo. `infra/` and `scripts/` build the cluster it runs on using `kubeadm` on three
DigitalOcean droplets. Any cluster with a load balancer and Argo CD works too.

Design: [DESIGN.md](DESIGN.md).

AI Disclosure: [AI_DISCLOSURE.md](AI_DISCLOSURE.md)

Live public nginx service: [nginx.mattcheston.com](https://nginx.mattcheston.com)

Live public Teleport cluster: [teleport.mattcheston.com](https://teleport.mattcheston.com)

## Contents

- [What you get](#what-you-get)
- ["Universal" Deployment](#universal-deployment)
- [Deploy on DigitalOcean](#deploy-on-digitalocean)
  - [1. Make it yours](#1-make-it-yours)
  - [2. Build](#2-build)
  - [3. DNS](#3-dns)
  - [4. Sign in](#4-sign-in)
  - [Tear down](#tear-down)
- [Layout](#layout)
- [Day two](#day-two)
- [Versions](#versions)

## What you get

| URL | What | Who |
|---|---|---|
| `https://teleport.<domain>` | Teleport | local users, passkey sign-in |
| `https://nginx.teleport.<domain>` | landing page, through Teleport | roles `hiring-viewer`, `demo-viewer` |
| `https://argocd.teleport.<domain>` | Argo CD UI, through Teleport | role `demo-viewer`, then Argo CD's own login |
| `https://nginx.<domain>` | landing page, public Ingress | anyone |

## "Universal" Deployment

This requires a Kubernetes cluster (1.30 or newer) with `type: LoadBalancer`
Services that get public addresses, a default StorageClass, and DNS you
control. First do [step 1, Make it yours](#1-make-it-yours), from the
DigitalOcean steps below; the rest of those steps do not apply. Then continue here: install Argo CD with
Helm, create the `deployer` user with a cluster-admin or similar kubeconfig on your
cluster, and deploy the root Application as the deployer:

```sh
# Install Argo CD if not already installed
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace --version 10.18.1
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo   # UI password for admin

# The deployer credential, then the root Application as the deployer.
ADMIN_KUBECONFIG=~/.kube/config ./scripts/kubeconfig-deployer.sh   # uses that file's current context
export KUBECONFIG=$PWD/infra/kubeconfig
kubectl apply -f bootstrap/
kubectl -n argocd get applications -w
```

The script applies the deployer's RBAC (`infra/rbac/deployer.yaml`), the
admission policy that pins deployer-written Applications to this repository at
`main` (`infra/rbac/deployer-policy.yaml`) and the Argo CD AppProjects
(`infra/argocd/projects.yaml`), has the cluster sign a client certificate
through a CSR using the `ADMIN_KUBECONFIG` credential, and writes
`infra/kubeconfig` for the deployer credential.

Then set up DNS as described in [step 3](#3-dns), by hand or by refactoring `infra/dns/`
for your DNS provider.

## Deploy on DigitalOcean

You need `terraform`, `kubectl`, `helm`, `doctl` logged in (`doctl auth init`),
an SSH key uploaded to the DigitalOcean account whose private half is loaded
locally, and a DNS zone. DNS is automated when the zone is at DNSimple and the
[`dnsimple` CLI](https://developer.dnsimple.com/cli/) is logged in
(`dnsimple auth login`); otherwise step 3 is three A records by hand.

### 1. Make it yours

Fork the repo, then replace the repo URL, domain and email everywhere they
appear (`sed -i.bak` works with both macOS and GNU sed; the last line removes
the backups):

```sh
REPO=https://github.com/<you>/<repo>.git DOMAIN=example.com EMAIL=you@example.com
grep -rl mattcheston --include='*.yaml' --include='*.tf' --include='*.html' \
  bootstrap argo-apps teleport-cluster teleport-kube-agent nginx traefik infra/dns infra/rbac infra/argocd \
  | xargs sed -i.bak -e "s#https://github.com/mattcheston/teleport-interview-matthewmalesky.git#$REPO#g" \
                     -e "s#me@mattcheston.com#$EMAIL#g" -e "s#mattcheston.com#$DOMAIN#g"
find . -name '*.bak' -not -path './.git/*' -delete
```

This replaces the Argo CD `repoURL`s (Applications, AppProjects and the
admission policy), the Teleport cluster name and proxy address, the Ingress
host, the DNS zone, the Let's Encrypt contact and the hostnames on the landing
page; `git diff` shows the result. Replace
`nginx/files/index.html` and `nginx/files/resume.pdf` with your own content.
Commit and push to `main` to update via GitOps.
For a private repo, give Argo CD credentials once it is running
(`argocd repo add <url> --username <user> --password <token>`).

`main` is the trust boundary. The deployer credential can only point Argo CD at
this repository's `main` branch, and Argo CD applies what it finds there as
cluster-admin, so whoever can push to `main` can deploy anything. Protect the
branch on GitHub (repository Settings, Branches, or a ruleset): require a pull
request and a review before merging, block force pushes and deletion, and limit
who may push. Write access to the repository without those rules is write
access to the cluster.

Cluster size, region and the SSH key name are variables in
`infra/terraform/variables.tf`; override any of them with `TF_VAR_<name>`.

### 2. Build

```sh
TF_VAR_ssh_key_name=<key name in DigitalOcean> ./scripts/kubeadm-up.sh
export KUBECONFIG=$PWD/infra/kubeconfig
```

Terraform creates the VPC, firewall and three droplets;
cloud-init installs containerd and kubeadm; the script runs `kubeadm init` and
`join`, installs Cilium, the DigitalOcean cloud controller manager and CSI
driver and Argo CD, and applies `bootstrap/`. It is idempotent, so re-run it
after a failure. SSH and the API are open only to the IP you ran it from
(`ADMIN_CIDR=` to widen). With the `dnsimple` CLI logged in, it also runs step 3.

This creates two kubeconfigs. `infra/kubeconfig` for basic deployment access and `infra/kubeconfig-admin` for cluster-admin, used for teardown, `tctl`, and break-glass.

### 3. DNS

```sh
./scripts/dns-apply.sh
```

Reads the two load balancer addresses from the cluster and writes three A
records at DNSimple through Terraform (`infra/dns/`). Run it again if it lists a
name as pending; Traefik's load balancer appears about a minute after Argo
syncs. Without DNSimple, create the records yourself:

| Record | Address from |
|---|---|
| `teleport.<domain>` and `*.teleport.<domain>` | `kubectl -n teleport get svc teleport-cluster` |
| `nginx.<domain>` | `kubectl -n traefik get svc traefik` |

Certificates issue within a couple of minutes of the names resolving.

### 4. Sign in

Creating Teleport users runs `tctl` inside the Auth pod, which needs the admin
kubeconfig:

```sh
export KUBECONFIG=$PWD/infra/kubeconfig-admin
kubectl -n teleport exec deploy/teleport-cluster-auth -- \
  tctl users add <you> --roles=editor,access,demo-viewer --ttl=1h
kubectl -n teleport exec deploy/teleport-cluster-auth -- \
  tctl users add <guest> --roles=hiring-viewer --ttl=48h
```

Each prints a one-time invite link; sign-in is password plus passkey. Argo CD's
own `admin` password needs the admin kubeconfig too: an Argo CD admin can edit
projects, so the deployer cannot read it.

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Tear down

```sh
./scripts/kubeadm-down.sh
```

Removes the DNS records, load balancers, volumes and the CCM's firewall, then
`terraform destroy`. The cluster costs about $97 a month while it is up.

## Layout

```
bootstrap/            root Application (apply once)
argo-apps/            one Application per component; sync waves order them
cert-manager/         wrapper chart, vendored upstream           wave 0
teleport-cluster/     wrapper chart: Auth, Proxy, Operator       wave 1
traefik/              wrapper chart + Let's Encrypt ClusterIssuer wave 1
teleport-access/      Teleport join token + roles as CRs (ours)  wave 2
nginx/                landing page chart + Ingress (ours)        wave 2
teleport-kube-agent/  wrapper chart: publishes nginx + Argo CD   wave 3
infra/terraform/      DigitalOcean VPC, droplets, firewall, cloud-init
infra/dns/            DNSimple records from the cluster's LB addresses
infra/rbac/           RBAC + admission policy for the deployer group
infra/argocd/         Argo CD AppProjects: where each Application may deploy (admin-applied)
scripts/              kubeadm-up.sh, kubeadm-down.sh, kubeconfig-deployer.sh, dns-apply.sh
```

Upstream charts are vendored as `charts/*.tgz`, so Argo CD never reaches out
to a chart repository. Every Application auto-syncs with prune and self-heal:
Git is the source of truth.

## Day two

- **Change the page.** Edit `nginx/files/index.html`, push. Argo CD rolls the
  pods within its three-minute poll.
- **Add an app.** New chart directory, copy `argo-apps/nginx.yaml` and adjust
  name, path, namespace and wave, and to publish it through Teleport add it to
  `apps` in `teleport-kube-agent/values.yaml` with a label a role matches.
  Add its namespace, and any cluster-scoped kind its chart renders, to the
  `apps` project in `infra/argocd/projects.yaml` and apply that with the admin
  kubeconfig (`kubectl apply --server-side -f infra/argocd/projects.yaml`);
  until then Argo CD reports the destination as not permitted.
- **Bump a chart.** Edit the version in the wrapper's `Chart.yaml`, run
  `helm dependency update ./<wrapper>`, commit `Chart.yaml`, `Chart.lock` and
  `charts/`.

## Versions

Kubernetes 1.37 (kubeadm), Cilium 1.20.5, DigitalOcean CCM v0.1.73 and CSI
v4.22.0, Argo CD v3.6.2 (`scripts/kubeadm-up.sh`; Helm chart 10.18.1 in the README); cert-manager v1.21.3,
Teleport charts 18.11.12, Traefik chart 42.4.1 (each wrapper's `Chart.yaml`);
Terraform providers pinned in each `.terraform.lock.hcl`.

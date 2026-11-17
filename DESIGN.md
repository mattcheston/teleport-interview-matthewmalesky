# Design notes
## App-of-apps

The root Application (`bootstrap/root-app.yaml`) points at `argo-apps/` and
recurses, so every Application in that directory is created automatically.
`argocd.argoproj.io/sync-wave` annotations order the rollout but are only
waiting for child apps to be created. Waiting for healthy state could
be added.

## Access through Teleport

- **teleport-cluster** is the Teleport cluster itself
- **teleport-access** is Teleport configuration and policies as Kubernetes objects (using the Teleport CRDs)
- **teleport-kube-agent** is the available Teleport apps and services

Sign-in is local users with WebAuthn as the only second factor, so a passkey.
Invite a user with `tctl users add <name> --roles=<roles> --ttl=<duration>`;
the link it prints is one-time and expires.

## Public access through an Ingress with TLS

- **Traefik** (`traefik/`) runs as a plain Ingress controller behind its own
  `LoadBalancer` Service: apps use standard `networking.k8s.io/v1` Ingress
  resources with `ingressClassName: traefik`, and none of Traefik's CRDs.
- **ClusterIssuer** `letsencrypt` (`traefik/templates/clusterissuer.yaml`)
  solves HTTP-01 challenges through that IngressClass.
- **Ingress** (`nginx/templates/ingress.yaml`, settings under `ingress:` in
  `nginx/values.yaml`), annotated `cert-manager.io/cluster-issuer: letsencrypt`.
  cert-manager's ingress-shim creates the Certificate, stores it in the
  `nginx-tls` Secret and renews it.

Swapping the controller means changing `ingress.className` in
`nginx/values.yaml` and the solver's `ingressClassName`.

## Vendored dependencies

`cert-manager/`, `teleport-cluster/`, `teleport-kube-agent/` and `traefik/` are
thin wrapper charts: each declares the upstream chart as a dependency in
`Chart.yaml`, and the pinned `.tgz` lives in its `charts/` directory,
committed. Our configuration lives in the wrapper's `values.yaml`, nested under
the subchart name (`traefik/` also carries one template of ours, the
ClusterIssuer).

Protects from dependency and upstream repository availability issues that can interrupt
software delivery, in exchange for a bit of extra complexity in dependency maintenance and
storing dependency archives in git which can become prohibitive with many upstream charts.

## Provider neutrality

Everything Argo CD manages works on any Kubernetes cluster that can satisfy a
`type: LoadBalancer` Service and has a default StorageClass. The only
cloud-specific lines are the two `service.beta.kubernetes.io/do-loadbalancer-name`
annotations on the Teleport and Traefik Services, which pin the DigitalOcean
load balancers' names and which every other provider ignores. `infra/` and `scripts/`
are specific to DigitalOcean resources.

## The cluster: kubeadm on DigitalOcean

One control plane node and two workers each on Ubuntu 24.04.  `scripts/kubeadm-up.sh` creates a running cluster with Argo CD.

| Layer | Tool | Where |
|---|---|---|
| VPC, droplets, cloud firewall, project | Terraform | `infra/terraform/` |
| Node prep: containerd, kubeadm/kubelet/kubectl, kernel settings | cloud-init | `infra/terraform/cloud-init.yaml.tftpl` |
| Control plane init, worker join | kubeadm over SSH | `scripts/kubeadm-up.sh` |
| Pod networking | Cilium | `scripts/kubeadm-up.sh` |
| LoadBalancer Services, node lifecycle, block storage | DigitalOcean CCM + CSI | `scripts/kubeadm-up.sh` |
| GitOps | Argo CD | `scripts/kubeadm-up.sh`, then `bootstrap/` |
| DNS records | Terraform (DNSimple + Kubernetes providers) | `infra/dns/`, applied by `scripts/dns-apply.sh` |

- Nodes register with their **VPC address** (`--node-ip`) and run with
  `--cloud-provider=external`, so the DigitalOcean CCM sets provider IDs and
  node addresses and creates the load balancers. The CCM is given the VPC id
  (`DO_CLUSTER_VPC_ID`) so load balancers are created in the nodes' VPC rather
  than the account default.
- The **API server** advertises its private IP to the nodes. Its public IP is
  in the certificate, so the kubeconfig the script writes to `infra/kubeconfig`
  works from your machine.
- The **cloud firewall** Terraform creates allows SSH and 6443 from one CIDR
  (your public IP when you ran the script; `ADMIN_CIDR=` overrides) and
  everything inside the VPC. Load balancer traffic is admitted by a second
  firewall the CCM manages itself (`PUBLIC_ACCESS_FIREWALL_NAME`): per
  Service, the service ports from anywhere and the kube-proxy health-check port
  from that load balancer only. DigitalOcean's managed Kubernetes uses the same
  arrangement.
- **Droplet names are node names**; the CCM relies on that to find them.
- Nothing account-specific is committed. The API token comes from
  `doctl auth token` (or `DIGITALOCEAN_TOKEN`); Terraform state, the
  kubeconfig and SSH `known_hosts` are gitignored.

## Cluster access

- **`deployer`** (`infra/kubeconfig`), for user access. The key never
  leaves the machine: `scripts/kubeconfig-deployer.sh` generates it locally using a CSR
  approved with an admin credential. The Roles and RoleBindings (`infra/rbac/deployer.yaml`) binds the 
  group to: full control of Argo CD Applications and ApplicationSets in the
  `argocd` namespace; `get` on the initial admin password Secret; and
  read-only everywhere else via the built-in `view` role plus nodes, CRDs,
  storage and the demo's custom resource groups. No `exec`, no other Secrets,
  no writes outside `argocd`.
- `kubernetes-admin` from `kubeadm` (`infra/kubeconfig-admin`), cluster-admin
  through the `kubeadm:cluster-admins` group.

## DNS as a second Terraform module

`infra/dns/` is an independent root module with its own state. The addresses it
needs belong to Services that Argo CD creates (Teleport's proxy, Traefik), so
the cluster module cannot know them. The DNS module reads them from the
Kubernetes API with `kubernetes_resources` data sources, which return empty
rather than failing while a Service does not exist yet, and writes one
`dnsimple_zone_record` per name:

| Name | Address from |
|---|---|
| `teleport.<domain>`, `*.teleport.<domain>` | Service `teleport/teleport-cluster` |
| `nginx.<domain>` | Service `traefik/traefik` |

`scripts/dns-apply.sh` waits for those addresses and applies. Names whose load
balancer is not there yet are listed in the `pending` output. The up script
runs it when credentials resolve; the down script destroys the records first,
while the cluster can still be read.

Credentials come from the [DNSimple CLI](https://developer.dnsimple.com/cli/)'s
stored login, the way the DigitalOcean ones come from `doctl`:
`scripts/lib/dnsimple-token.sh` takes the active context's account from
`dnsimple auth list` and its token from the CLI's credentials file, because the
CLI never prints tokens and Terraform's provider needs the raw value.
`DNSIMPLE_TOKEN` in the environment overrides this; `DNSIMPLE_CONTEXT` picks a
non-active context.
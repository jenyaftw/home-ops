# AGENTS.md

Instructions for AI agents (and humans) working in this repo.

## What this is

A 3-node Talos Linux cluster on Proxmox, GitOps-managed by Flux. Every
change goes through git - nothing gets `kubectl apply`'d by hand and left
that way.

- **Nodes**: `talos-cp1/2/3`, all control-plane, no dedicated workers.
- **CNI**: Cilium. kube-proxy replacement, Gateway API instead of an
  Ingress controller, L2Announcements + LB-IPAM for LoadBalancer Services,
  Hubble metrics for L7/HTTP visibility.
- **GitOps**: Flux, run via Flux Operator (`kubernetes/flux/`), not
  `flux bootstrap`.
- **Secrets**: SOPS + age. Private key at `age.key` (gitignored, never
  commit it). Every secret in git is a `*.sops.yaml` file.
- **Storage**: `proxmox-lvm` (sergelogvinov/proxmox-csi-plugin) is the
  default StorageClass - provisions a dedicated Proxmox disk per PVC that
  follows the pod if it reschedules.
- **Database**: one shared CloudNativePG Postgres cluster
  (`kubernetes/apps/database/postgres`) and one shared Redis. Apps get
  their own `Database` + `DatabaseRole` pointed at the shared cluster
  instead of running their own.
- **Auth**: Authentik (`kubernetes/apps/authentik/`), embedded outpost in
  Proxy mode. An app opts in by routing its HTTPRoute at `authentik-server`
  instead of itself - see "Protecting an app with Authentik" below.
- **Gateways**: `internal` (LAN-only) and `external` (public, restricted to
  Cloudflare's IP ranges), both in `kube-system`.
- **Observability**: Prometheus/Grafana (`kube-prometheus-stack`), Loki +
  Alloy for logs, all in the `observability` namespace. Any ServiceMonitor
  or PodMonitor anywhere in the cluster gets picked up automatically.

## Repo layout

```
infra/                      OpenTofu - Proxmox VMs, Talos machine config
kubernetes/flux/            Flux's own bootstrap (FluxInstance, GitRepository)
kubernetes/apps/<ns>/<app>/ one dir per app
  ks.yaml                   Flux Kustomization
  app/                      the actual manifests this Kustomization applies
```

`kubernetes/apps/<namespace>/kustomization.yaml` lists every app's `ks.yaml`
under that namespace. `kubernetes/apps/kustomization.yaml` lists every
namespace directory.

## Adding a new app

New, general-purpose apps go in `kubernetes/apps/default/<app-name>/`,
using the [bjw-s app-template](https://bjw-s-labs.github.io/helm-charts/docs/app-template/)
chart. See `.claude/skills/deploy-app/SKILL.md` for the exact steps and a
working example.

## Conventions

- Set `metadata.namespace` explicitly on every namespaced resource. Only
  add `spec.targetNamespace` to a Kustomization when every resource inside
  it truly belongs to one namespace - it force-overrides all of them, which
  breaks anything that needs to span namespaces (an app plus its
  `Database`/`DatabaseRole` in `database`, for example).
- A HelmRepository/OCIRepository shared by multiple apps gets declared
  once and referenced by name from the others. Two Kustomizations owning
  the same source object race on prune.
- SOPS secrets get a one-line comment on *why* it's structured the way it
  is (e.g. "duplicated in namespace X because Y can only reference
  same-namespace secrets"), not a restatement of what it contains.
- Validate before pushing: `kubectl kustomize <path>` for structure,
  `helm template <chart> -f <values>` for anything you're not sure will
  render cleanly.
- After pushing: `flux reconcile source git flux-system`, then
  `flux reconcile kustomization <name>`. Don't wait for the hourly
  interval.
- Default StorageClass is `proxmox-lvm` - omit `storageClassName` unless
  you need something else.

## Protecting an app with Authentik

Point the app's HTTPRoute `backendRefs` at `authentik-server` (in the
`authentik` namespace) instead of the app's own Service, then add a
ProxyProvider + Application entry to
`kubernetes/apps/authentik/authentik/app/blueprint.yaml` and list the new
provider in the embedded outpost's `providers` (that list is authoritative,
not additive - every protected app has to be in it). You'll also need a
`ReferenceGrant` entry in `kubernetes/apps/authentik/authentik/app/referencegrant.yaml`
for your app's namespace if it isn't already listed.

## Hard-won lessons

Things that failed in non-obvious ways and are worth knowing before you
touch these areas again:

- **cilium-envoy runs with `hostNetwork: true`.** Gateway-routed traffic
  reaches a pod under Cilium's reserved `host`/`ingress` identities, not
  its normal pod identity. A `NetworkPolicy` won't match this traffic - use
  a `CiliumNetworkPolicy` with `fromEntities: [host, ingress]`.
- **CNPG `DatabaseRole` password secrets need both a `username` and a
  `password` key.** A password-only secret fails with "username key
  doesn't exist inside the secret" - easy to miss since the error doesn't
  mention the missing key by name.
- **`tofu apply` on a Proxmox VM's disk block re-detaches CSI-managed
  disks.** Terraform reconciles the VM's entire disk list and doesn't know
  about disks the CSI plugin attached out-of-band. After any VM disk
  change, check for stuck PVCs and delete the corresponding
  `VolumeAttachment` if the pod can't remount.
- **New namespaces default to the `baseline` PodSecurity level.** Anything
  needing `hostNetwork`/`hostPath`/`hostPID` (node-exporter, CSI node
  plugins) needs its namespace labeled
  `pod-security.kubernetes.io/enforce: privileged`.
- **A Deployment with one RWO PVC and the default RollingUpdate strategy
  deadlocks on any change that recreates the pod** - the new pod waits
  forever for a volume the old one hasn't released yet. Set
  `strategy: {type: Recreate}` for anything with non-shared persistent
  storage.
- **Unquoted dates in HelmRelease values get parsed as timestamps, not
  strings.** `from: 2024-04-01` silently becomes `2024-04-01T00:00:00Z`
  once it round-trips through the HelmRelease CR's YAML→JSON pipeline.
  Quote them.
- **Authentik's embedded outpost needs `AUTHENTIK_HOST` set** (an env var
  on the authentik-server/worker Deployments), or it builds browser-facing
  OAuth redirects against `localhost` instead of the real hostname.
- **Grafana's "unified storage" subsystem hammers its own database with
  concurrent transactions.** sqlite can't keep up (constant
  `SQLITE_BUSY`, pegs the CPU, hangs requests) - point it at Postgres
  instead.
- **A stopped/rebooted node doesn't evict its pods for 5 minutes**
  (`tolerationSeconds: 300` on the default `not-ready`/`unreachable`
  tolerations). A brief blip just resumes the same pod in place; only a
  sustained outage triggers a reschedule elsewhere.
- **`external-dns` (Cloudflare/public) only syncs HTTPRoutes labeled
  `external-dns.io/enabled: "true"`** - a deliberate opt-in gate so
  internal-only apps never get a public DNS record by accident.
  `external-dns-pihole` (LAN-only) has no such filter and syncs every
  route on the `internal` Gateway unconditionally.
- **A FUSE mount created in a sidecar container needs propagation set on
  *both* sides to become visible in the main container**: the sidecar's
  volumeMount needs `mountPropagation: Bidirectional`, and the main
  container's mount of that same volume needs `mountPropagation:
  HostToContainer`. Setting only one side leaves the main container
  seeing the empty directory underneath instead of the mount.
- **rclone's `--vfs-cache-mode full` can hang `readdir()` indefinitely on
  a WebDAV backend** while `stat()` on the same path returns instantly -
  a confusing partial-hang, not an outright failure. It also works
  against the point of a virtual/debrid mount (it eagerly caches file
  contents locally). Leave VFS caching off unless you have a specific
  reason to need it.

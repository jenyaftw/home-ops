---
name: deploy-app
description: Add a new application to the homelab cluster using the bjw-s app-template Helm chart. Use when the user asks to deploy, add, or install a new app/service to the cluster.
---

New apps live in `kubernetes/apps/default/<app-name>/`, built on the
[bjw-s app-template](https://bjw-s-labs.github.io/helm-charts/docs/app-template/)
chart via the shared `app-template` OCIRepository already set up in
`kubernetes/apps/default/app-template/`. Read `AGENTS.md` first for the
cluster's overall conventions - this skill only covers the app scaffold.

## Steps

1. **Create the directory**: `kubernetes/apps/default/<app-name>/` with an
   `app/` subdirectory.

2. **`ks.yaml`** (the Flux Kustomization, one level up from `app/`):

   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: <app-name>
     namespace: flux-system
   spec:
     targetNamespace: default
     path: ./kubernetes/apps/default/<app-name>/app
     sourceRef:
       kind: GitRepository
       name: flux-system
     prune: true
     wait: true
     interval: 1h
     retryInterval: 1m
     timeout: 5m
     dependsOn:
       - name: app-template
         namespace: flux-system
   ```

   If the app needs its own Postgres `Database`/`DatabaseRole` (living in
   the `database` namespace, not `default`), drop `targetNamespace` and set
   `metadata.namespace` explicitly on every resource instead - see
   `kubernetes/apps/authentik/authentik/app/` for a worked example of that
   pattern.

3. **`app/helmrelease.yaml`**:

   ```yaml
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: <app-name>
     namespace: default
   spec:
     interval: 1h
     chartRef:
       kind: OCIRepository
       name: app-template
       namespace: default
     install:
       remediation:
         retries: 3
     upgrade:
       remediation:
         retries: 3
     values:
       controllers:
         main:
           containers:
             main:
               image:
                 repository: <image>
                 tag: <tag>
               env: {}
               resources:
                 requests:
                   cpu: 10m
                   memory: 64Mi
                 limits:
                   memory: 128Mi

       service:
         main:
           controller: main
           ports:
             http:
               port: 80

       # Only if the app needs to be reachable via a hostname.
       route:
         main:
           kind: HTTPRoute
           hostnames:
             - <app-name>.jenya.lol
           parentRefs:
             - name: internal
               namespace: kube-system
           rules:
             - backendRefs:
                 - identifier: main
                   port: 80
           # Required on the "external" gateway only - external-dns
           # (Cloudflare) is opt-in and ignores routes without this label,
           # so public DNS records don't get created by accident. Not
           # needed for "internal" - external-dns-pihole syncs every route
           # on that gateway unconditionally.
           # labels:
           #   external-dns.io/enabled: "true"

       # Only if the app needs persistent storage.
       persistence:
         data:
           type: persistentVolumeClaim
           storageClass: proxmox-lvm
           accessMode: ReadWriteOnce
           size: 1Gi
           globalMounts:
             - path: /data
   ```

   Use `parentRefs: [{name: external, namespace: kube-system}]` instead
   (or in addition) if the app needs to be reachable from outside the LAN
   - remember the external Gateway is Cloudflare-proxied only, and to add
     the `external-dns.io/enabled: "true"` label above so external-dns
     actually publishes it.

4. **`app/kustomization.yaml`**:

   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ./helmrelease.yaml
   ```

5. **Register it**: add `- ./<app-name>/ks.yaml` to
   `kubernetes/apps/default/kustomization.yaml`.

6. **Secrets**, if the app needs any: create `app/secret.sops.yaml` with
   `kubectl create secret generic ... --dry-run=client -o yaml`, then
   `sops --encrypt --in-place <file>`. Add it to `app/kustomization.yaml`
   and reference it from the HelmRelease via `envFrom`/`envValueFrom` in
   `controllers.main.containers.main`.

## Before pushing

```
kubectl kustomize kubernetes/apps/default/<app-name>/app
kubectl kustomize kubernetes/apps/default
```

Both must succeed. If unsure a HelmRelease's `values` will render cleanly,
render it directly:

```
helm template <app-name> oci://ghcr.io/bjw-s-labs/helm/app-template \
  --version 5.2.x -f <(yq '.spec.values' app/helmrelease.yaml)
```

## After pushing

```
flux reconcile source git flux-system
flux reconcile kustomization <app-name>
kubectl get pods -n default
```

If exposed via a `route`, confirm end-to-end:

```
curl -sk -L -o /dev/null -w "%{http_code}\n" https://<app-name>.jenya.lol/
```

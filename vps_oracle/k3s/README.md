# vps_oracle/k3s

Cluster foundation (phase A) and GitOps bootstrap (phase B) for the [K3s roadmap](../../docs/superpowers/specs/2026-08-05-k3s-cloud-native-platform-roadmap.md). See the [phase A design doc](../../docs/superpowers/specs/2026-08-05-k3s-phase-a-cluster-foundation-design.md) and [phase B design doc](../../docs/superpowers/specs/2026-08-07-k3s-phase-b-gitops-design.md) for the full rationale.

**As of phase B, don't `kubectl apply` anything under `manifests/` (except the one-time `argocd/apps/root.yaml` bootstrap) or `apps/*/k8s/` by hand** — those are GitOps-managed and ArgoCD's `selfHeal` will fight you. Edit the file, commit, push instead.

## Installed versions

| Component | Version | Resolved on |
|---|---|---|
| k3s | `v1.36.2+k3s1` | 2026-08-05 |
| Cilium | `1.20.0` | 2026-08-05 |
| ArgoCD | `10.3.0` (chart), `v3.5.0` (app/CLI) | 2026-08-07 |

## Install

1. `sudo mkdir -p /etc/rancher/k3s`
2. `sudo cp install/config.yaml /etc/rancher/k3s/config.yaml`
3. `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.2+k3s1" sh -`
4. `mkdir -p ~/.kube`
5. `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown ubuntu:ubuntu ~/.kube/config && chmod 600 ~/.kube/config`
6. Append KUBECONFIG export to `~/.profile` so k3s's kubectl uses the user's config by default:
   ```bash
   echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.profile
   ```
7. Verify kubectl works: `bash -lc 'kubectl get nodes'`

Re-applying `install/config.yaml` after an edit: copy it to `/etc/rancher/k3s/config.yaml` again, then `sudo systemctl restart k3s`.

**Non-login shells:** `~/.profile` is only read by login shells. A plain non-login shell (`bash -c '...'` instead of `bash -lc '...'`, and most cron/CI/script contexts) won't pick up `KUBECONFIG`, and `kubectl` fails with a permission-denied error on `/etc/rancher/k3s/k3s.yaml` that reads like a bug rather than an unset env var. Those contexts need `export KUBECONFIG=$HOME/.kube/config` set explicitly before calling `kubectl`.

## Cilium

Installed via Helm with `kube-proxy-replacement: true` — k3s's own kube-proxy is disabled (see `install/config.yaml`). Hubble relay + UI are enabled for flow observability.

Reinstall/upgrade: `helm upgrade cilium cilium/cilium --version 1.20.0 --namespace kube-system -f cilium/values.yaml`

Check health: `cilium status --wait`. View flows: `kubectl -n kube-system port-forward svc/hubble-ui 12000:80`, then open `http://localhost:12000` through an SSH tunnel.

### Pod CIDR

Cilium's cluster-pool IPAM defaults to carving `10.0.0.0/8` into per-node `/24`s. On this host that allocated `10.0.0.0/24` — which is *also* this node's real Oracle VCN subnet (`enp0s6` is `10.0.0.95/24`, DHCP-assigned). The collision silently black-holed traffic to any other host on the VCN: `ip route get 10.0.0.50` resolved via `cilium_host` instead of the physical NIC.

Fixed on 2026-08-06 by pinning an explicit, non-default pod CIDR in `cilium/values.yaml`, clear of both the host subnet and the docker bridge networks (`172.17-24.0.0/16`):
```yaml
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.42.0.0/16"
    clusterPoolIPv4MaskSize: 24
```
Applied with the same `helm upgrade` command above, then forced IPAM to re-allocate: `kubectl delete ciliumnode --all && kubectl -n kube-system rollout restart daemonset/cilium` (safe only because the `workloads` namespace was empty at the time — deleting the `CiliumNode` invalidates in-flight pod IPs). Every `kube-system` deployment holding a pod IP from before the migration needs a `kubectl rollout restart deployment/<name>` afterward, since Cilium won't reconcile an already-running pod's IP on its own — `hubble-relay`, `hubble-ui`, and `metrics-server` needed this immediately; `local-path-provisioner` was missed on the first pass (it kept running "successfully" on its stale `10.0.0.x` IP with zero apiserver connectivity and no probes to surface it — caught later via `cilium status`'s `Cluster Pods: N/M managed by Cilium` count reading less than the total pod count). **After any future re-IPAM, check `cilium status | grep "Cluster Pods"` and restart every `kube-system` deployment until it reads `N/N`, don't assume three known names is the complete list.**

Verify: `kubectl get ciliumnode -o jsonpath='{.items[0].spec.ipam.podCIDRs}'` → `10.42.x.0/24`; `ip route get 10.0.0.50` → resolves via `enp0s6`, not `cilium_host`.

Note: `kubectl get node -o yaml`'s `spec.podCIDR` shows k3s's own built-in default, which is irrelevant since Cilium's cluster-pool IPAM is authoritative — it now happens to also read `10.42.0.0/24`, purely coincidental with the CIDR chosen above, not a sign the two are actually linked.

### NPM traffic is `world` identity, not in-cluster

Cilium classifies any traffic entering from the `npm` docker container (via the compose-node-IP → NodePort bridge, see the root README's NPM section — not Docker's `host-gateway`, which doesn't reach a Cilium NodePort at all) as `world` identity — it never sees it as coming from something in-cluster, because it isn't. A namespace-level default-deny `NetworkPolicy` (like `manifests/verification/netpol-test.yaml`'s `deny-all-ingress`) blocks `world` traffic exactly like any other non-selected source. This matters for every real service migrated behind NPM in a later phase: default-deny + NPM ingress needs an explicit ingress-allow rule for `world`/host-external traffic, not just intra-cluster pod/namespace selectors.

**Known gotcha (fixed) — host firewall blocked pod → host-networked-service traffic.** This host's iptables `INPUT` chain (persisted at `/etc/iptables/rules.v4` via `iptables-persistent`) only allow-listed new inbound TCP on 22/80/443, default-REJECT otherwise. Cilium's kube-proxy replacement does socket-level load-balancing: any pod that connects to a ClusterIP backed by the node itself gets that connection transparently rewritten to `<node-ip>:<port>`. That rewritten packet leaves the pod via the node's physical NIC (Cilium's "Direct Routing" mode) and is filtered by the host's normal `INPUT` chain like any other inbound connection — so any port not on the 22/80/443 allow-list got ICMP `host-prohibited` rejected. This bit three host-networked ports during Phase A bring-up: `6443` (kube-apiserver — broke CoreDNS readiness, which cascaded into cluster DNS and Hubble Relay both failing), `4244` (cilium-agent's `hubble-peer` gRPC service — broke Hubble Relay directly), and `10250` (kubelet's metrics API — broke `metrics-server`).

Fix applied (scoped to the Cilium pod CIDR, not opened to the internet):
```bash
sudo iptables -I INPUT 9 -p tcp -s 10.42.0.0/16 -m tcp --dport 6443 -j ACCEPT
sudo iptables -I INPUT 10 -p tcp -s 10.42.0.0/16 -m tcp --dport 4244 -j ACCEPT
sudo iptables -I INPUT 11 -p tcp -s 10.42.0.0/16 -m tcp --dport 10250 -j ACCEPT
```
Originally applied 2026-08-05 scoped to `10.0.0.0/24`; updated 2026-08-06 to `10.42.0.0/16` as part of the pod-CIDR fix above — the original scoping was accidentally as wide as the entire VCN subnet, not just the pod network, since `10.0.0.0/24` was both at the time. `/etc/iptables/rules.v4` was updated via `iptables-save` (previous version backed up alongside it, timestamped) so all three rules survive a reboot; no follow-up needed. Verify the current pod CIDR with `kubectl get ciliumnode -o jsonpath='{.items[0].spec.ipam.podCIDRs}'` before reusing this pattern after any future re-IPAM. If a future workload needs to reach some other host-networked port from a pod, the same pattern applies: check `cilium-dbg service list` for a backend on the node's own IP, and add the matching scoped `INPUT` rule against the current pod CIDR (`10.42.0.0/16`).

## ArgoCD

Installed via Helm (`argo/argo-cd` chart) into the `argocd` namespace. Dex and the notifications controller are disabled (`argocd/values.yaml`) — no SSO; no alert-routing integration yet. Single replica everywhere, no HA — this is a single-node cluster.

The Helm release is bootstrapped once by hand (Install section below), then handed over to ArgoCD itself to self-manage via `argocd/apps/argocd.yaml` — see the "App of apps" section for the full layout.

**Accounts:** the built-in `admin` superuser is disabled (`configs.cm.admin.enabled: "false"` in `argocd/values.yaml`, declarative). The only account is `jerome`, declared in the same file (`configs.cm.accounts.jerome: apiKey,login`) with full `role:admin` RBAC (`configs.rbac.policy.csv`) — grant is declarative, but the password itself is a secret and isn't in git.

**External URL:** `configs.cm.url` is set to `https://argocd.jerome.cloudns.asia`. Without it, ArgoCD defaults to the placeholder `https://argocd.example.com` — harmless for most things, but it sends you to the wrong place on logout.

**Setting/resetting a local account's password:** `argocd account update-password` reliably fails when logged in via `--core` (`unable to extract token claims` — that RPC needs a real JWT session, which `--core` doesn't provide). Worse: **a local account's password hash in `argocd-secret` has repeatedly changed on its own after a sync of the `argocd` Application that restarts the `argocd-server`/`repo-server` pods** (observed multiple times bumping `jerome`'s `passwordMtime` and bcrypt hash, sometimes with no corresponding `update-password` call in the logs at all). Confirmed this isn't the Helm chart's doing — `helm template` renders `argocd-secret` as a completely empty shell, no password-related keys — so the mechanism is something in ArgoCD's own server-side account/settings reconciliation, not fully root-caused. **Treat any account's password as unverified after any sync that touches `argocd/values.yaml`, and re-verify with a real login immediately after, every time** — don't assume a password set earlier still works. The reliable way to set one, bypassing the API entirely:
```bash
NEW_PW='<pick a password>'
HASH=$(docker run --rm httpd:alpine htpasswd -nbBC 10 <account> "$NEW_PW" | cut -d: -f2)
kubectl -n argocd patch secret argocd-secret --type merge -p \
  "{\"stringData\": {\"accounts.<account>.password\": \"$HASH\", \"accounts.<account>.passwordMtime\": \"$(date -u +%FT%TZ)\"}}"
```
Then verify immediately: `argocd login argocd.jerome.cloudns.asia:443 --username <account> --password "$NEW_PW" --grpc-web`. Note this login needs the real domain (or a port-forward) and `--grpc-web` — `--core` never touches the password/session system at all, so it can't be used to confirm a password actually works.

**CLI access:** `argocd login --core` talks to the cluster directly via the current kubeconfig context (make sure `kubectl config set-context --current --namespace=argocd` first) — this avoids `kubectl port-forward`, which works fine for plain `curl` against `argocd-server` but reliably resets the connection specifically for the `argocd` CLI's own login/gRPC-web traffic on this cluster (root cause not fully diagnosed; `--core` sidesteps it entirely and is simpler for a single-operator setup with local `kubectl` access anyway). If you do need the UI/API over a real network path (not just CLI), use `kubectl -n argocd port-forward svc/argocd-server <local-port>:80` — port `8080` is already taken on this host by an unrelated compose service, pick something else.

**Known transient issue:** on first install, `argocd-server`'s logs may show a handful of `redis: ... connect: no route to host` errors in the first couple of seconds after the pods start, then nothing further — this looks like Cilium's service map not being fully programmed yet at the exact moment `argocd-server` opens its first Redis connection, not a persistent problem. It self-resolved without intervention and didn't recur; if it ever shows up as a *sustained* pattern (not just at startup), treat it like phase A's documented host-firewall-blocks-node-local-ClusterIP-traffic gotcha (see the Cilium section above) — check `cilium-dbg service list` for the backend and, if needed, scope an `iptables INPUT` allow rule for the current pod CIDR rather than one port at a time, since on a single-node cluster every ClusterIP's backend is node-local.

**Never test self-heal by scaling `argocd-repo-server` to 0.** It's the component that renders manifests for every Application's sync, including reconciling itself — scaling it down deadlocks self-heal (nothing can compute the fix because the thing that computes fixes is what's down); `argocd app sync`/`diff` also fail outright while it's down for the same reason. Recovery requires a manual `kubectl -n argocd scale deployment argocd-repo-server --replicas=1`. To actually verify self-heal, break something in a regular workload Application instead (e.g. `placeholder-hello`, see below) — that has no such circularity.

### Install

1. `helm repo add argo https://argoproj.github.io/argo-helm && helm repo update`
2. `kubectl create namespace argocd`
3. `helm install argocd argo/argo-cd --version "10.3.0" --namespace argocd -f argocd/values.yaml`

Re-applying `argocd/values.yaml` after an edit: prefer editing the file and letting ArgoCD's own self-management (`argocd/apps/argocd.yaml`) sync it, once that's bootstrapped. Only fall back to `helm upgrade argocd argo/argo-cd --version "10.3.0" --namespace argocd -f argocd/values.yaml` if self-management itself is broken.

### App of apps

`argocd/apps/root.yaml` is the one Application applied by hand (`kubectl apply -f argocd/apps/root.yaml`) — nothing else exists yet to create it. Everything else in `argocd/apps/` is discovered automatically because `root` watches that whole directory (including `root.yaml` itself, which is why `root` shows up as one of its own managed resources — harmless, and means even `root` self-heals against manual edits). Children:

- `argocd` — self-manages this Helm release (multi-source: the `argo-cd` chart + `argocd/values.yaml` from this repo as an external values source) plus `argocd/manifests/argocd-server-nodeport.yaml` (a third plain-directory source in the same Application, since it's infrastructure for exposing ArgoCD itself)
- `phase-a-foundation` — the namespace/quota/limitrange from phase A (now GitOps-managed, no longer hand-applied)
- `placeholder-hello` — the demo app proving the CI → GitOps loop (see `vps_oracle/k3s/apps/placeholder-hello/`)

All Applications run `prune: true` / `selfHeal: true` — manual `kubectl` changes to anything they manage get reverted automatically, usually within seconds. **Editing `argocd.yaml` (or any other file directly under `argocd/apps/`) requires syncing `root`, not the Application the edit is about** — `root` is what applies changes to the Application *objects themselves*; syncing `argocd` only re-applies whatever `sources` are already live, silently ignoring an uncommitted-to-cluster edit to its own spec. To add a brand new Application, write its manifest into `argocd/apps/`, commit, push, and either wait for the next poll or force it: `argocd app sync root`.

**CLI gotcha:** `argocd-repo-server` renders manifests for every Application's sync, including reconciling itself. Never test self-heal by scaling it to 0 — that deadlocks self-heal (and breaks `argocd app sync`/`diff` for everything) since the thing that would compute the fix is what's down. Recovery is a manual `kubectl -n argocd scale deployment argocd-repo-server --replicas=1`. Use a regular workload (e.g. `placeholder-hello`) to verify self-heal instead.

### CI pipeline (placeholder-hello)

`.github/workflows/placeholder-hello.yml` triggers on push to `vps_oracle/k3s/apps/placeholder-hello/**` (plus manual `workflow_dispatch`): builds `linux/arm64` on a standard `ubuntu-latest` x64 runner via QEMU emulation (no self-hosted runner, no server resource cost), Trivy-scans the result and fails the job on any `CRITICAL` finding, then signs it with keyless Cosign (GitHub OIDC → Sigstore Fulcio/Rekor — no key material anywhere). Verify a signature: `cosign verify ghcr.io/jeromefromcn/placeholder-hello:<sha> --certificate-identity-regexp '^https://github.com/Jeromefromcn/docker-gitops/.github/workflows/placeholder-hello.yml@refs/heads/main$' --certificate-oidc-issuer https://token.actions.githubusercontent.com`.

Deploying a new image is a manual two-step, not automated: after CI signs and pushes a new tag, edit `apps/placeholder-hello/k8s/deployment.yaml` to point at it, commit, push. This is deliberate — it still satisfies "deploys go through git, not `kubectl apply`" without pulling in an image-updater's extra moving parts. Watch for the CI workflow's `paths:` filter also matching `k8s/deployment.yaml` itself — bumping the tag re-triggers a (harmless, redundant) rebuild of unchanged app source.

The `placeholder-hello` GHCR package (`ghcr.io/jeromefromcn/placeholder-hello`) is public — its content is a static placeholder page with nothing sensitive, and public avoids needing an `imagePullSecret` in the cluster.

## Namespace & quota

`manifests/namespace.yaml` creates the `workloads` namespace — where phase C+ deploys real services. `manifests/resourcequota.yaml` caps the namespace at `requests.cpu: "1"`, `requests.memory: 2Gi`, `limits.cpu: "1"`, `limits.memory: 2Gi` (request == limit, no slack — phase A's only tenant is the smoke-test workload; bump the quota directly if a later phase needs more, it won't disturb pods already running). `manifests/limitrange.yaml` gives any container that omits its own `resources` a default of `100m`/`128Mi` requests and `200m`/`256Mi` limits, so a workload that forgets to set resources can't silently eat the whole quota. Neither applies to `kube-system` (Cilium, Hubble, CoreDNS, local-path-provisioner) — the quota only governs `workloads`, that's expected, not a gap.

## Verification runbook

`manifests/` holds the reusable connectivity/policy verification tooling for this cluster — kept in the repo so later phases can rerun it, not just phase A. Apply order:

1. Namespace/quota (idempotent, only needed if the namespace was ever deleted):
   ```bash
   kubectl apply -f manifests/namespace.yaml -f manifests/resourcequota.yaml -f manifests/limitrange.yaml
   ```
2. Smoke-test workload — Deployment + NodePort Service + `netpol-tester` pod:
   ```bash
   kubectl apply -f manifests/verification/smoke-test.yaml
   ```
   **Do not** also apply `manifests/verification/netpol-test.yaml` yet — see the header comment in both files. Applying the NetworkPolicy first blocks the very connectivity this step exists to prove.
3. Run the four checks:
   - **NodePort:** `curl http://localhost:30080` → nginx welcome page.
   - **ResourceQuota usage:** `kubectl describe resourcequota workloads-quota -n workloads` → `Used` reflects the smoke-test pod's requests/limits.
   - **NetworkPolicy enforcement:** `kubectl apply -f manifests/verification/netpol-test.yaml`, then `kubectl -n workloads exec netpol-tester -- wget -qO- --timeout=3 http://smoke-test.workloads.svc.cluster.local` → times out (proves Cilium enforces `NetworkPolicy`, not just routes traffic). Then `kubectl delete -f manifests/verification/netpol-test.yaml` before the NPM check below — NPM's traffic is `world` identity (see above) and the deny-all policy would block it too, which isn't what that check is testing.
   - **NPM end-to-end:** create a temporary NPM proxy host per the root README's "给服务接入 NPM 反代" section (note its NodePort gotcha: Forward Hostname/IP must be the node's literal IP, not a hostname), then `curl` the domain from outside. Delete the proxy host afterward.
4. Teardown:
   ```bash
   kubectl delete -f manifests/verification/smoke-test.yaml
   kubectl delete -f manifests/verification/netpol-test.yaml   # only if still applied
   kubectl get pods -n workloads                  # expect: No resources found
   ```

## homepage

Migrated from `vps_oracle/compose/homepage` in phase C. Config (`settings.yaml`/`widgets.yaml`/`services.yaml`/`bookmarks.yaml`/`custom.css`/`custom.js`) lives in `apps/homepage/k8s/configmap.yaml` — still git-versioned, just delivered as a ConfigMap instead of a bind mount. An initContainer copies it into a writable `emptyDir` at `/app/config` because homepage writes its own request log there and a ConfigMap volume is read-only.

The docker-container-status widget (`config/docker.yaml`, and each service card's `container`/`server` keys) was dropped — it depended on a read-only `/var/run/docker.sock` mount with no k8s equivalent worth the RBAC to replace it. The global `resources`/`search`/`datetime` widgets are unaffected.

Exposed via NodePort `30081` → NPM (`homepage.jerome.cloudns.asia`), same domain as before. The old compose container (`vps_oracle/compose/homepage`) is stopped, not removed — kept as a rollback path per the roadmap's migration principles.

**NPM cutover was scripted, not manual.** `vps_oracle/compose/npm/.npm-automation.env` + the API pattern documented in `vps_oracle/compose/npm/README.md` (login → bearer token → `GET`/`PUT /api/nginx/proxy-hosts/{id}`) let a `PUT` update `forward_host`/`forward_port` on the existing proxy host in place, same effect as the manual UI steps but scriptable. Still re-verify `ssl_forced`/`http2_support` after the `PUT` — the known "resets itself" bug isn't specific to the UI path.

## trilium

Migrated from `vps_oracle/compose/trilium` in phase C. Unlike homepage, trilium holds real user data (notes), so this wasn't a config-only swap — the migration procedure was:

1. Stop the compose container (no writes during migration).
2. Apply `apps/trilium/k8s/pvc.yaml` plus a disposable seed Pod (`apps/trilium/migration/seed-pod.yaml`) that mounts the same PVC — needed because the `local-path` StorageClass is `WaitForFirstConsumer`, so the PV's host directory doesn't get created until something actually mounts the PVC.
3. Copy the old `/etc/trilium/data` into the PV's host directory (`sudo cp -a` — this host doesn't have `rsync` installed), then `chown` it to uid 1000 (the PV directory is created root-owned; trilium's process runs as uid 1000).
4. Delete the seed Pod, commit the PVC, then deploy the real Application — ArgoCD adopts the already-populated PVC instead of creating an empty one.

**Correction to the original plan:** `local-path-provisioner`'s PV uses `spec.local.path`, not `spec.hostPath.path` — the volume type is `local`, not `hostPath`. `kubectl get pv <name> -o jsonpath='{.spec.local.path}'` is the right lookup.

**Data-integrity check gotcha:** a `find -type f | wc -l` taken immediately after stopping the compose container (15 files) didn't match a re-check taken a minute later (13 files) — SQLite's `-wal`/`-shm` files got consolidated during the last moments of container shutdown. A full path listing diff between source and destination matched exactly, and re-querying the source again also settled at 13 — the first count was just taken too early, not evidence of a bad copy. Don't trust a file count taken in the same breath as stopping the container; re-check a few seconds later before treating it as the baseline.

The container intentionally has no `securityContext.runAsUser` — the image's entrypoint starts as root and self-drops to uid 1000 via `su`, and forcing a different startup UID breaks that.

**`enableServiceLinks: false` is required on the pod spec.** Without it, Kubernetes injects a `TRILIUM_PORT=tcp://<clusterIP>:8080` env var into the container (auto-generated from the `trilium` Service's name), colliding with trilium's own `TRILIUM_PORT` config variable — which expects a plain integer — and crash-looping the app with `FATAL ERROR: Invalid port value "tcp://...". This is a general risk any time a Service name matches an app's own env-var naming convention, not trilium-specific; worth checking for on every future migration.

**Quota headroom bit during the fix rollout.** After correcting `enableServiceLinks`, the Deployment's rolling update tried to run both the old (crash-looping) and new pod briefly, and `workloads-quota`'s `limits.cpu` had no room for both trilium pods (500m each) on top of homepage/placeholder-hello's existing usage. Manually scaling the old (broken) ReplicaSet to 0 freed the quota and let the new pod get admitted — a direct instance of the tight-headroom risk already flagged in the phase C design doc.

Exposed via NodePort `30082` → NPM (`trilium.jerome.cloudns.asia`), same domain as before. The old compose container is stopped, not removed.

**Known limitation:** there is no backup mechanism for this data beyond the original `/etc/trilium/data` on the host (pre-existing gap, not introduced by this migration). The PVC's `local-path` StorageClass has `reclaimPolicy: Delete` — removing `pvc.yaml` from git and letting ArgoCD prune it deletes the underlying data directory too. The original `/etc/trilium/data` is untouched by the migration (the copy only reads from it) so it's a recovery path today, but that stops being true whenever phase H decides to clean up decommissioned compose data.

## Handoff to phase C

Phase C (first real service migrations) picks up from here: a working GitOps loop (ArgoCD app-of-apps, `selfHeal`/`prune` on everything) and a proven CI pattern (`placeholder-hello.yml`) to copy for the first real service — same build→Trivy→Cosign→GHCR shape, just point it at a real Dockerfile and give the resulting Application its own entry under `argocd/apps/`. ArgoCD's UI is reachable at `https://argocd.jerome.cloudns.asia` (NPM, `self-only` access list) for watching syncs during migrations.

# vps_oracle/k3s

Cluster foundation (phase A) and GitOps bootstrap (phase B) for the [K3s roadmap](../../docs/superpowers/specs/2026-08-05-k3s-cloud-native-platform-roadmap.md). See the [phase A design doc](../../docs/superpowers/specs/2026-08-05-k3s-phase-a-cluster-foundation-design.md) and [phase B design doc](../../docs/superpowers/specs/2026-08-07-k3s-phase-b-gitops-design.md) for the full rationale.

**As of phase B, don't `kubectl apply` anything under `manifests/` (except the one-time `argocd/apps/root.yaml` bootstrap) or `apps/*/k8s/` by hand** — those are GitOps-managed and ArgoCD's `selfHeal` will fight you. Edit the file, commit, push instead.

## Installed versions

| Component | Version | Resolved on |
|---|---|---|
| k3s | `v1.36.2+k3s1` | 2026-08-05 |
| Cilium | `1.20.0` | 2026-08-05 |
| ArgoCD | `10.3.0` (chart), `v3.5.0` (app/CLI) | 2026-08-07 |
| Sealed Secrets | `2.19.1` (chart), `v0.38.4` (app/`kubeseal`) | 2026-08-15 |
| Kyverno | `3.8.2` (chart), `v1.18.2` (app) | 2026-08-15 |
| Trivy Operator | `0.35.0` (chart), `0.33.0` (app) | 2026-08-15 |
| Istio (base/istiod/cni/ztunnel) | `1.30.3` (chart+app) | 2026-08-18 |
| Gateway API | `v1.6.1` (standard channel) | 2026-08-18 |

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

**`helm upgrade` alone does not restart cilium-agent — after any `values.yaml` change (especially anything under `socketLB`), always follow up with:**
```bash
kubectl -n kube-system rollout restart daemonset/cilium
```
**and verify the live datapath, not the ConfigMap:**
```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep 'Socket LB Coverage'
```
Expect `Hostns-only` if `socketLB.hostNamespaceOnly` is set to `true`; `Full` means the restart never happened. This chart puts no ConfigMap checksum on the DaemonSet's pod template, so `helm upgrade` only updates the ConfigMap — the agent reads `socketLB` settings once at startup and bakes them into the cgroup BPF program it compiles, so a values-only change leaves the running pods untouched and silently stale, with no error anywhere. Full root cause and history in `cilium/values.yaml`'s comments above the `socketLB:` block.

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

**Known gotcha (fixed) — host firewall blocked pod → host-networked-service traffic.** This host's iptables `INPUT` chain (hand-written rules in `vps_oracle/host-firewall/host-firewall.sh` since 2026-08-16) only allow-lists new inbound TCP on 22/80/443, default-REJECT otherwise. Cilium's kube-proxy replacement does socket-level load-balancing: any pod that connects to a ClusterIP backed by the node itself gets that connection transparently rewritten to `<node-ip>:<port>`. That rewritten packet leaves the pod via the node's physical NIC (Cilium's "Direct Routing" mode) and is filtered by the host's normal `INPUT` chain like any other inbound connection — so any port not on the 22/80/443 allow-list got ICMP `host-prohibited` rejected. This bit three host-networked ports during Phase A bring-up: `6443` (kube-apiserver — broke CoreDNS readiness, which cascaded into cluster DNS and Hubble Relay both failing), `4244` (cilium-agent's `hubble-peer` gRPC service — broke Hubble Relay directly), and `10250` (kubelet's metrics API — broke `metrics-server`).

Fix applied (scoped to the Cilium pod CIDR, not opened to the internet):
```bash
sudo iptables -I INPUT 9 -p tcp -s 10.42.0.0/16 -m tcp --dport 6443 -j ACCEPT
sudo iptables -I INPUT 10 -p tcp -s 10.42.0.0/16 -m tcp --dport 4244 -j ACCEPT
sudo iptables -I INPUT 11 -p tcp -s 10.42.0.0/16 -m tcp --dport 10250 -j ACCEPT
```
Originally applied 2026-08-05 scoped to `10.0.0.0/24`; updated 2026-08-06 to `10.42.0.0/16` as part of the pod-CIDR fix above — the original scoping was accidentally as wide as the entire VCN subnet, not just the pod network, since `10.0.0.0/24` was both at the time. The three rules now live in `vps_oracle/host-firewall/host-firewall.sh`, applied at boot by `host-firewall.service` — the single source of truth for hand-written host firewall rules. (History: they were first "persisted" by saving a full `iptables-save` snapshot into `/etc/iptables/rules.v4`; that snapshot also froze Docker's per-network runtime rules, and netfilter-persistent replaying it at every boot blackholed container traffic on 2026-08-16 — root cause and postmortem in `vps_oracle/host-firewall/README.md`. netfilter-persistent is now disabled; **never** re-run `iptables-save > /etc/iptables/rules.v4` or `netfilter-persistent save` on this host.) Verify the current pod CIDR with `kubectl get ciliumnode -o jsonpath='{.items[0].spec.ipam.podCIDRs}'` before reusing this pattern after any future re-IPAM. If a future workload needs to reach some other host-networked port from a pod, the same pattern applies: check `cilium-dbg service list` for a backend on the node's own IP, and add the matching scoped `INPUT` rule **to `host-firewall.sh`** against the current pod CIDR (`10.42.0.0/16`).

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

**Never test self-heal by scaling `argocd-repo-server` to 0.** It's the component that renders manifests for every Application's sync, including reconciling itself — scaling it down deadlocks self-heal (nothing can compute the fix because the thing that computes fixes is what's down); `argocd app sync`/`diff` also fail outright while it's down for the same reason. Recovery requires a manual `kubectl -n argocd scale deployment argocd-repo-server --replicas=1`. To actually verify self-heal, break something in a regular workload Application instead (e.g. `hello-backend`, see below) — that has no such circularity.

### Install

1. `helm repo add argo https://argoproj.github.io/argo-helm && helm repo update`
2. `kubectl create namespace argocd`
3. `helm install argocd argo/argo-cd --version "10.3.0" --namespace argocd -f argocd/values.yaml`

Re-applying `argocd/values.yaml` after an edit: prefer editing the file and letting ArgoCD's own self-management (`argocd/apps/argocd.yaml`) sync it, once that's bootstrapped. Only fall back to `helm upgrade argocd argo/argo-cd --version "10.3.0" --namespace argocd -f argocd/values.yaml` if self-management itself is broken.

### App of apps

`argocd/apps/root.yaml` is the one Application applied by hand (`kubectl apply -f argocd/apps/root.yaml`) — nothing else exists yet to create it. Everything else in `argocd/apps/` is discovered automatically because `root` watches that whole directory (including `root.yaml` itself, which is why `root` shows up as one of its own managed resources — harmless, and means even `root` self-heals against manual edits). Children:

- `argocd` — self-manages this Helm release (multi-source: the `argo-cd` chart + `argocd/values.yaml` from this repo as an external values source) plus `argocd/manifests/argocd-server-nodeport.yaml` (a third plain-directory source in the same Application, since it's infrastructure for exposing ArgoCD itself)
- `phase-a-foundation` — the namespace/quota/limitrange from phase A (now GitOps-managed, no longer hand-applied)
- `hello` — the two-tier `hello-frontend`/`hello-backend` practice app proving the CI → GitOps loop (see `vps_oracle/k3s/apps/hello/k8s`), successor to the retired `placeholder-hello`
- `gateway-api` (phase F+G) — the Gateway API standard-channel CRDs, `sync-wave: -4` so the waypoint `Gateway` and every `HTTPRoute` have the CRDs they need before Istio itself comes up
- `istio-base`, `istio-istiod`, `istio-cni`, `istio-ztunnel` (phase F+G) — the four Helm-chart Applications making up Istio Ambient mode, one Application per Helm release, `sync-wave`d `-3` → `-2` → `-1`/`-1` (`base` → `istiod` → `cni`/`ztunnel`) — see the "Istio Ambient / PR Lanes" section below
- `pr-lanes` (phase F+G) — **an `ApplicationSet`, not a plain Application** (`argocd/apps/pr-lanes-appset.yaml`): its GitHub `pullRequest` generator creates one `hello-pr-<number>` Application per open PR labeled `pr-lane`, each an isolated header-routed lane of `hello-backend`

All Applications run `prune: true` / `selfHeal: true` — manual `kubectl` changes to anything they manage get reverted automatically, usually within seconds. **Editing `argocd.yaml` (or any other file directly under `argocd/apps/`) requires syncing `root`, not the Application the edit is about** — `root` is what applies changes to the Application *objects themselves*; syncing `argocd` only re-applies whatever `sources` are already live, silently ignoring an uncommitted-to-cluster edit to its own spec. To add a brand new Application, write its manifest into `argocd/apps/`, commit, push, and either wait for the next poll or force it: `argocd app sync root`.

**CLI gotcha:** `argocd-repo-server` renders manifests for every Application's sync, including reconciling itself. Never test self-heal by scaling it to 0 — that deadlocks self-heal (and breaks `argocd app sync`/`diff` for everything) since the thing that would compute the fix is what's down. Recovery is a manual `kubectl -n argocd scale deployment argocd-repo-server --replicas=1`. Use a regular workload (e.g. `hello-backend`) to verify self-heal instead.

### CI pipeline (hello-backend)

`.github/workflows/hello-backend.yml` triggers on `push` to `main` (path filter `vps_oracle/k3s/apps/hello/backend/**`) and on `pull_request` events (`opened`/`synchronize`/`reopened`/`labeled`, same path filter), plus manual `workflow_dispatch`. On `pull_request`, the build job's `if` only runs when the PR carries the `pr-lane` label (`github.event_name != 'pull_request' || contains(github.event.pull_request.labels.*.name, 'pr-lane')`) — opening or pushing to a PR without that label triggers the workflow but skips the job, so labeling a PR is what turns its lane's image build on.

When it runs: builds `linux/arm64` on a standard `ubuntu-latest` x64 runner via QEMU emulation (no self-hosted runner, no server resource cost), tags the image with the PR head SHA (`pull_request`) or the push SHA (`main`), Trivy-scans it and fails the job on any `CRITICAL` finding with a fix available (`ignore-unfixed: true`), then signs it with keyless Cosign (GitHub OIDC → Sigstore Fulcio/Rekor — no key material anywhere). Verify a signature: `cosign verify ghcr.io/jeromefromcn/hello-backend@<digest> --certificate-identity-regexp '^https://github.com/Jeromefromcn/docker-gitops/.github/workflows/hello-backend.yml@refs/heads/main$' --certificate-oidc-issuer https://token.actions.githubusercontent.com`.

Deploying the baseline (`main`) image is still a manual two-step, not automated: after CI signs and pushes a new digest, edit `apps/hello/k8s/backend-deployment.yaml` to point at it, commit, push — same "deploys go through git" rationale as before. PR lanes work differently: the `pr-lanes` ApplicationSet (`argocd/apps/pr-lanes-appset.yaml`) Kustomize-patches each lane's image to the PR's head SHA automatically, no manual deployment edit needed per PR.

`hello-frontend` has no CI workflow of its own — it still reuses the old signed `placeholder-hello` image (`apps/hello/k8s/frontend-deployment.yaml`), unchanged since phase F+G retired that app.

**That image can no longer be rebuilt from this repo.** Commit `64e42c9` deleted the retired app's whole build context along with it — `Dockerfile`, `index.html`, and `.github/workflows/placeholder-hello.yml` are all gone — so the digest running today exists only as a GHCR blob (plus this node's containerd cache). It can't be rescanned by CI, re-signed, or patched, and its contents (`nginxinc/nginx-unprivileged:1.31.3-alpine3.24` plus a static `index.html`) are frozen at what that base shipped in phase B. Nothing is broken while it sits there — Kyverno verifies the signature made when it was built, and its in-cluster `VulnerabilityReport` reads 0 CRITICAL (checked 2026-08-21) — but note the trap: if a fixable CRITICAL ever lands in that frozen base, `require-vuln-scan-clean` denies the pod on its next recreation and there is no patched image to move to. Restoring the build context is the way out, and it's cheap: `git show 64e42c9^:vps_oracle/k3s/apps/placeholder-hello/Dockerfile` (likewise `index.html` and the workflow beside them), renamed to `hello-frontend`, rebuilt through the same build→Trivy→Cosign shape as `hello-backend.yml`.

The `hello-backend` GHCR package (`ghcr.io/jeromefromcn/hello-backend`) is public — same reasoning as before: nothing sensitive, avoids needing an `imagePullSecret` in the cluster.

## Sealed Secrets

Phase E replaced the hand-created, out-of-band Secrets left over from phase D (`workloads/vikunja`, `dify/dify-secrets`, `llm/open-webui`) with `SealedSecret` resources committed to git. The controller (`sealed-secrets/sealed-secrets` chart, dedicated `sealed-secrets` namespace, `fullnameOverride: sealed-secrets`) decrypts them in-cluster; ArgoCD only ever sees ciphertext.

**Adding a new secret** (or migrating another hand-created one):

```bash
kubectl get secret <name> -n <namespace> -o json \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations, .status)' \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  > vps_oracle/k3s/sealed-secrets/secrets/<name>.sealed.yaml
```

Commit the output (safe — it's ciphertext), push, then delete the old bare Secret (`kubectl delete secret <name> -n <namespace>`) so the controller can take ownership without a naming conflict. The `sealed-secrets` Application (`prune: true`/`selfHeal: true`) picks up new files under `vps_oracle/k3s/sealed-secrets/secrets/` automatically.

**Key backup is the single point of failure.** The controller's signing key (`sealed-secrets-key*` Secret in the `sealed-secrets` namespace) is the only way to decrypt every `SealedSecret` in the repo — this is a single-node cluster with no etcd HA to fall back on. A GPG-encrypted export lives at `/home/ubuntu/secrets-backup/` on the host (outside git, outside the cluster), with a copy meant to live somewhere physically separate from this VPS too. If the key is ever rotated or the controller reinstalled from scratch, redo that backup — don't assume the old one still applies.

**Gitignore note:** the repo-wide `secrets/` ignore pattern (for compose `.env`-adjacent secrets) would silently swallow `SealedSecret` manifests too, since they also live under a directory named `secrets/`. `.gitignore` has an explicit negation (`!vps_oracle/k3s/sealed-secrets/secrets/**`) carving this path back out — don't remove it, and don't assume `git status` showing nothing here means "nothing to commit" without checking `git check-ignore` first if a new sealed-secrets file goes missing from `git add`.

## Namespace & quota

`manifests/namespace.yaml` creates the `workloads` namespace — where phase C+ deploys real services. `manifests/resourcequota.yaml` caps the namespace at `requests.cpu: "2"`, `requests.memory: 4Gi`, `limits.cpu: "2"`, `limits.memory: 4Gi` (request == limit, no slack; raised 2026-08-10 from the phase A default of `1`/`2Gi` once homepage+trilium+CCR's NPM entry pushed `limits.cpu` close to the old cap — see the "Before starting phase D" note below, this was that bump. Node has 4 CPU / 24Gi total, cluster-wide `limits.cpu` usage was ~47% before this change — bump the quota directly if a later phase needs more, it won't disturb pods already running). `manifests/limitrange.yaml` gives any container that omits its own `resources` a default of `100m`/`128Mi` requests and `200m`/`256Mi` limits, so a workload that forgets to set resources can't silently eat the whole quota. Neither applies to `kube-system`. A hard `ResourceQuota` there is deliberately skipped — it requires every pod in the namespace to declare `resources.requests` or be rejected outright, and Cilium's agent/envoy DaemonSets shipped with zero declared resources, so quota'ing the namespace risked the CNI itself failing to reschedule after a node reboot. That's a reason to skip the *quota*, though, not a reason to skip *resources* on the pods themselves — leaving Cilium/Hubble with no requests/limits at all (as they were until 2026-08-13, see `resources:` in `cilium/values.yaml`) meant nothing bounded them, which was the actual gap. CoreDNS and metrics-server ship with partial resources from k3s's own bundled manifests; `local-path-provisioner` still has none and isn't managed by this repo.

**Known gotcha — a rolling update can stall on this quota with zero warning.** `kubectl rollout restart` (or any Deployment change) creates a surge pod before killing the old one; if the namespace is already near the `limits.cpu`/`limits.memory` ceiling, the new pod's `FailedCreate: exceeded quota` events pile up silently (`kubectl describe rs <new-rs>` shows them; `kubectl rollout status` just hangs) and the old ReplicaSet quietly keeps recreating its own pod if you delete it by hand, re-claiming the freed quota before the new RS can grab it. If this happens: `kubectl scale rs <old-rs> -n workloads --replicas=0` directly (not just deleting the pod) to make room and let the new RS take over — hit twice already (trilium's `enableServiceLinks` fix, and homepage's CCR-card rollout), see the trilium section and the root README's homepage section for the blow-by-blow.

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

**2026-08-18: migrated back to compose** (`vps_oracle/compose/homepage`) — no longer running on k3s. This section is kept as historical record of the phase C k3s migration; see the [migration plan](../../docs/superpowers/plans/2026-08-18-k3s-to-compose-migration.md) for the reversal.

Migrated from `vps_oracle/compose/homepage` in phase C. Config (`settings.yaml`/`widgets.yaml`/`services.yaml`/`bookmarks.yaml`/`custom.css`/`custom.js`) lives in `apps/homepage/k8s/configmap.yaml` — still git-versioned, just delivered as a ConfigMap instead of a bind mount. An initContainer copies it into a writable `emptyDir` at `/app/config` because homepage writes its own request log there and a ConfigMap volume is read-only.

The docker-container-status widget (`config/docker.yaml`, and each service card's `container`/`server` keys) was dropped — it depended on a read-only `/var/run/docker.sock` mount with no k8s equivalent worth the RBAC to replace it. The global `resources`/`search`/`datetime` widgets are unaffected.

Was exposed via NodePort `30081` → NPM (`homepage.jerome.cloudns.asia`), same domain as before. (Contrary to what this paragraph originally claimed, the old compose container/files were actually deleted from git in commit `1e6bcf9` on 2026-08-16, not kept — that claim was already stale before the 2026-08-18 reversal above; the new compose stack was rebuilt from that commit's git history instead.)

**NPM cutover was scripted, not manual.** `vps_oracle/compose/npm/.npm-automation.env` + the API pattern documented in `vps_oracle/compose/npm/README.md` (login → bearer token → `GET`/`PUT /api/nginx/proxy-hosts/{id}`) let a `PUT` update `forward_host`/`forward_port` on the existing proxy host in place, same effect as the manual UI steps but scriptable. Still re-verify `ssl_forced`/`http2_support` after the `PUT` — the known "resets itself" bug isn't specific to the UI path.

## trilium

**2026-08-18: migrated back to compose** (`vps_oracle/compose/trilium`) — no longer running on k3s; notes data was copied from this PVC's host path back to `/etc/trilium/data`. This section is kept as historical record of the phase C k3s migration; see the [migration plan](../../docs/superpowers/plans/2026-08-18-k3s-to-compose-migration.md) for the reversal.

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

Was exposed via NodePort `30082` → NPM (`trilium.jerome.cloudns.asia`), same domain as before.

**Known limitation:** there is no backup mechanism for this data beyond the original `/etc/trilium/data` on the host (pre-existing gap, not introduced by this migration). The PVC's `local-path` StorageClass has `reclaimPolicy: Delete` — removing `pvc.yaml` from git and letting ArgoCD prune it deletes the underlying data directory too. The original `/etc/trilium/data` is untouched by the migration (the copy only reads from it) so it's a recovery path today, but that stops being true whenever phase H decides to clean up decommissioned compose data.

## Timezone

The root README's convention (`TZ: "Asia/Hong_Kong"`) applies here too, but **whether it actually works depends entirely on whether the image ships `tzdata`** — setting `$TZ` on an image with no `/usr/share/zoneinfo` silently falls back to UTC instead of erroring, so a missing effect is easy to miss:

| Component | `TZ` set? | Actual `date` output | Works? |
|---|---|---|---|
| ArgoCD (all components, incl. the `argocd-application-controller` StatefulSet) | `global.env` / `controller.env` in `argocd/values.yaml` | `HKT` | ✅ |
| trilium | `environment.TZ` in its Deployment | `HKT` | ✅ |
| Cilium (agent/operator/hubble-relay/hubble-ui) | `extraEnv` in `cilium/values.yaml` | `UTC` | ❌ image has no `/usr/share/zoneinfo` — left set anyway (harmless, and future Cilium image bumps may add tzdata) |
| homepage | `environment.TZ` in its Deployment | `UTC` | ❌ same cause, not investigated further (low priority — see phase C's design doc) |
| hello (frontend/backend), kube-system system pods (CoreDNS, local-path-provisioner, metrics-server) | not set | `UTC` | expected, never configured |

**This isn't just cosmetic — it's a log-correlation risk.** Once more than one component prints timestamps in different zones, manually cross-referencing raw log text across services (e.g. "did the NPM cutover happen before or after this ArgoCD sync") gets error-prone: the same wall-clock moment prints as two different clock times depending on which service logged it. Two mitigations, deliberately not more:
- `kubectl logs --timestamps` / `docker logs --timestamps` prepend the container runtime's own capture timestamp (RFC3339 with an explicit UTC offset) ahead of whatever the app itself printed — that prefix is always unambiguous and safe to cross-reference regardless of the app's own TZ handling. Use it, don't trust the app's printed text alone, when correlating across services.
- No aggregated log/report system exists for the cluster yet (no Loki/ELK — only `vps_oracle/compose/monitoring` covers metrics, not logs), so this risk is latent, not active, today. If one gets added later, ingest and normalize to UTC at the collector — that's the standard fix for exactly this problem, not chasing tzdata into every image. Don't spend more effort forcing every k8s component to display HKT than this table already has.

## Kyverno / Trivy Operator / PSA baseline

Phase E's admission-control stack: Trivy Operator (`trivy-operator/trivy-operator` chart `0.35.0`, `trivy-system` ns, `Standalone`/Job-only scan mode) generates `VulnerabilityReport` CRDs cluster-wide; Kyverno (`kyverno/kyverno` chart `3.8.2`, `kyverno` ns, **admission-controller only** — `backgroundController`/`reportsController`/`cleanupController` all disabled) enforces three `ClusterPolicy` resources against them (all three started in `Audit` mode; current enforcement status is summarized in "Net effect" below):

- `restrict-image-registry` — Cosign keyless signature verification, scoped to `ghcr.io/jeromefromcn/*` only (`imageReferences`, not `skipImageReferences` — everything else is untouched by default)
- `require-vuln-scan-clean` — denies Pods with a `VulnerabilityReport` showing a `CRITICAL` vulnerability that **has a fix available** (`fixedVersion != ''`). Originally cluster-wide; narrowed on 2026-08-18 to self-built images only (`app in (hello-frontend, hello-backend)`, same selector pattern as `restricted-self-built`) — see the 2026-08-18 finding below for why. Deliberately does NOT deny on unfixable CRITICALs — blocking those has no resolution path and would just deadlock the workload forever
- `restricted-self-built` — Kubernetes `restricted` Pod Security profile via Kyverno's built-in `validate.podSecurity`, scoped by pod label (`app in (hello-frontend, hello-backend)`) rather than namespace, since `workloads` mixes self-built and third-party images

Adding a new self-built workload: add it to `restricted-self-built.yaml`'s label selector, and to `require-vuln-scan-clean.yaml`'s label selector (same `app in (...)` pattern, since 2026-08-18) if it should also get the CVE gate.

**Known Kyverno gotchas hit during rollout, worth knowing before touching these policies again:**
- **CRD size vs. client-side apply**: Kyverno's `ClusterPolicy`/`Policy` CRDs have OpenAPI schemas large enough that `kubectl.kubernetes.io/last-applied-configuration` (client-side apply's annotation) exceeds Kubernetes' 262144-byte `metadata.annotations` limit, failing CRD sync outright with `metadata.annotations: Too long`. Fixed by adding `ServerSideApply=true` to the `kyverno` Application's `syncOptions` — don't remove it.
- **`verifyImages` + `Audit` mode**: `mutateDigest` defaults to `true`, which Kyverno's own admission webhook rejects when `validationFailureAction: Audit` (`mutateDigest must be set to false for 'Audit' failure action`). Any new `verifyImages` rule needs `mutateDigest: false` explicit.
- **Autogen breaks custom `context.apiCall` JMESPath**: Kyverno's autogen feature (on by default) generates Deployment/ReplicaSet/etc. variant rules by rewriting `request.object.metadata.*` paths to `request.object.spec.template.metadata.*`. A policy using a custom `context.apiCall.urlPath` template with hardcoded `{{request.object.metadata.*}}` breaks under that rewrite (confirmed via live admission-controller logs: `JMESPath query failed: Unknown key "namespace" in path`). `require-vuln-scan-clean` disables autogen entirely (`pod-policies.kyverno.io/autogen-controllers: "none"`) since Pod-level interception is sufficient for its purpose. `verifyImages` and `podSecurity` validators are autogen-aware and don't have this problem.
- **`argocd-application-controller` OOMKilled once Kyverno was added**: its 512Mi memory limit was sized before Kyverno's large CRD manifests entered the diff/comparison workload — bumped to 1Gi in `argocd/values.yaml`. If adding more large-CRD components later (service mesh CRDs are a likely future culprit — see phase G), re-check this headroom before assuming a stuck sync is something else.

**Audit-mode findings (2026-08-15, first pass — not yet a full multi-day observation window):**
- **`apprise` (caronc/apprise:v1.5.1): 13 CRITICAL CVEs, zero with a fix available.** Correctly *not* denied by `require-vuln-scan-clean` (no `fixedVersion` on any of them) — this is an accepted, currently-unresolvable risk, not a policy gap. Re-check periodically for upstream fixes.
- **CVE-2026-59873 (`node-tar` DoS via crafted gzip bomb) — RESOLVED (2026-08-16).** The vulnerable tar lives in the **npm CLI's internal bundled copy** (`/usr/local/lib/node_modules/npm/node_modules/tar`, version follows the node base image, not the app), so no upstream release of any of the affected apps fixes it. homepage (`tar 7.5.11`) and trilium (`tar 7.5.15`) were rebuilt as **security wrapper images** (`vps_oracle/k3s/images/`, built+signed by the `patched-images` workflow, cosign v3.1.3) that replace npm with 11.19.0 (bundles tar `7.5.19`) — the patched images are Trivy-clean (CI gate: 0 CRITICAL). homepage also moved `v1.13.2 -> v2.0.0` in the process: v1.13.2 additionally carried tar `7.5.11` as an app dependency (pnpm), which a wrapper can't remove; v2.0.0 dropped it (config verified compatible via a live smoke test). The third affected workload, **sillytavern** (tar `7.5.11`), was deleted outright on 2026-08-16 (service removed from k8s + compose + NPM + homepage; its fixable protobufjs CVE-2026-41242 is therefore also gone from the fleet).
- **Previously-assumed arm64 scan gap — corrected 2026-08-18, not actually a gap.** Earlier testing saw "no child with platform linux/amd64" on single-arch arm64 manifests and concluded the cluster-side trivy-operator skips our self-built arm64 images (`placeholder-hello`, `vikunja-notify-relay`) entirely. Re-checked against live data on 2026-08-18: both have current `VulnerabilityReport`s (`placeholder-hello`: 0 CRITICAL; `vikunja-notify-relay`: 0 CRITICAL/1 LOW/5 MEDIUM) — the node (`instance-20260321-2043`) is itself `arm64` (Oracle Ampere), so the operator's scan Job runs natively there instead of needing an amd64 child manifest. In-cluster coverage for these two is real, not absent; the CI `build-scan-sign` Trivy gate remains the primary protection regardless (it runs on an x64 GitHub runner via QEMU and gates the build itself), this is just a bonus, not the load-bearing check. Accepted as-is — no further investment planned.
- **2026-08-18 — Enforce cutover check found the original cluster-wide scope of `require-vuln-scan-clean` was not actually Enforce-safe, despite three quiet Audit days.** Audit mode only emits a `PolicyViolation` event when a Pod is newly admitted; most cluster pods (argocd's own four components, `kube-system/metrics-server`, dify's `plugin-daemon`/`web`/`db-postgres`/`pgvector`, and seven `lab-environment` components) simply hadn't restarted since fresh CRITICAL-with-fix CVEs landed in their `VulnerabilityReport`s (e.g. `CVE-2025-68121`, Go stdlib, on argocd's own binaries), so the observation window never actually exercised this path — the silence was an artifact of nothing having been recreated, not evidence of safety. Flipping straight to `Enforce` would have risked those pods — including `argocd-server` itself — being rejected on their next recreation, self-locking the GitOps control plane it runs on. Resolved by narrowing `require-vuln-scan-clean` to the same self-built-only scope as `restrict-image-registry`/`restricted-self-built` (`app in (placeholder-hello, vikunja-notify-relay)`). Third-party CVEs (argocd, dify, lab-environment, kube-system) are accepted as an ongoing upstream-upgrade concern outside this policy's scope, not gated by admission control.
- **Cosign verification inside Kyverno — RESOLVED (2026-08-15).** Root cause was a two-layer format/storage mismatch, not a TUF/Rekor problem: (1) CI's cosign v3 signs store signatures as Sigstore bundles in OCI referrers (no legacy `sha256-<digest>.sig` tag), which Kyverno's default `type: Cosign` verify path never reads — hence "no signatures found"; (2) cosign ≤v3.0.x bundles go-containerregistry <v0.21.7, which writes the referrers fallback-tag index entry (GHCR has no referrers API) with `artifactType` copied from `config.mediaType` (`application/vnd.oci.empty.v1+json`) instead of the manifest's real artifactType — so even `type: SigstoreBundle`, which filters referrers by the `application/vnd.dev.sigstore.bundle` prefix, found nothing ("no matching signatures found"). The CLI verified fine because cosign ≥v3.1 defaults `--new-bundle-format=true` and doesn't filter by the index entry's artifactType. Fix: pin CI cosign to v3.1.3 (ggcr v0.21.7 writes correct entries), switch the policy to `type: SigstoreBundle`, replace the never-matching `subject: "*.yml@..."` wildcard (`keyless.subject` is exact-match; use `subjectRegExp`) with a regex. Verified end-to-end for both self-built images: `placeholder-hello@sha256:3b8929d1...` and `vikunja-notify-relay@sha256:163e88a1...` each pass `restrict-image-registry` in-cluster (`image attestors verification succeeded, verifiedCount=1`).
- **`vikunja-notify-relay`'s GHCR push was blocked by `permission_denied: write_package` — RESOLVED (2026-08-16).** The package is user-owned (the original image was pushed manually in phase D, not by this pipeline), so the repo's GITHUB_TOKEN had no access; fixed by granting the package "Manage Actions access" for `Jeromefromcn/docker-gitops` in the GitHub web UI. Two follow-on issues surfaced in the first rebuild: the base image `python:3.12.7-alpine3.20` failed the Trivy gate on fixable CVE-2026-31789 (openssl 3.3.2-r1), resolved by bumping to `python:3.12.13-alpine3.22` (openssl 3.5.x); the Deployment was then pinned from the `:1.1.0` tag to the new signed digest `sha256:163e88a1...`.
- **Pre-existing quota headroom issues surfaced (not caused) by restart-testing these policies**, in namespaces unrelated to phase E's own additions: `dify-quota`'s `limits.cpu` was already at 2850m/3000m and `workloads-quota` at 1700m/2000m before any of this work started — restarting `dify`'s app tier (`api`/`worker`/`worker-beat`/`web`) and `trilium` each hit the same `RollingUpdate`-vs-tight-quota deadlock already fixed for `llm` via `Recreate` strategy (commit `bd79748`). **RESOLVED (2026-08-16)**: the `Recreate` strategy was applied to all remaining single-replica Deployments in `dify` (`api`/`web`/`worker`/`worker-beat`/`ssrf-proxy`; `plugin-daemon` already had it) and `workloads` (`apprise`/`evidence-os-website`/`homepage`/`placeholder-hello`/`trilium`/`vikunja`/`vikunja-notify-relay`). No service in these namespaces has more than one replica, so the Recreate downtime is one pod's cold-start; RollingUpdate offered nothing here since surge could never be scheduled.

**Net effect (updated 2026-08-18): all three policies are `Enforce`.** `restrict-image-registry` and `restricted-self-built` flipped after a clean 3-day Audit window with zero violations, then verified to actually block (unsigned `:latest` and an explicit `runAsUser: 0` override on a `placeholder-hello`-labeled pod were both rejected at admission). `require-vuln-scan-clean` was narrowed to self-built images only (see the 2026-08-18 finding above) before flipping — third-party workloads (argocd, dify, lab-environment, kube-system, etc.) are no longer in this policy's scope at all, so their pre-existing fixable-CRITICAL CVEs can't block their own admission; those stay a separate, ongoing patching concern, not a phase E blocker.

**2026-08-18, later the same day: `dify` (all 9 containers) and `evidence-os-website` migrated off k3s back to/into compose** — see the [migration plan](../../docs/superpowers/plans/2026-08-18-k3s-to-compose-migration.md). The `dify` namespace no longer exists; the third-party-CVE carve-out above is kept as historical record of why the policy was scoped that way, but `dify` pods are no longer part of what it needs to account for.

**2026-08-19 — homepage/trilium security wrapper images retired.** Both services are plain `docker compose` containers now (moved off k3s in the same 2026-08-18 migration), so neither `require-vuln-scan-clean` nor the CI `build-scan-sign` Trivy gate apply to them anymore — the wrapper images (`vps_oracle/k3s/images/`, `.github/workflows/patched-images.yml`) existed solely to satisfy those, so both were removed and the compose files reverted to the plain upstream images (`ghcr.io/gethomepage/homepage:v2.0.0`, `triliumnext/trilium:v0.104.1`). This reintroduces CVE-2026-59873 (node-tar DoS via crafted gzip bomb, in npm's bundled tar, no upstream fix) unscanned and unmonitored on both — accepted as low-severity (DoS-only, no known exploit in the wild) now that nothing enforces a clean scan on these two anyway.

**2026-08-18, same day, third round: `apprise`, `vikunja` (+ `vikunja-notify-relay`), and `llm` (`llama-cpp`+`open-webui`) also migrated back to compose** — see the [second migration plan](../../docs/superpowers/plans/2026-08-18-k3s-to-compose-migration-part2.md). The `llm` namespace no longer exists. This completes the reversal of every phase C/D service migration — at this point only `lab-environment`/`headlamp`/`placeholder-hello` (k3s-native, no compose predecessor) remain on k3s. The `restricted-self-built`/`require-vuln-scan-clean` `app in (placeholder-hello, vikunja-notify-relay)` scoping above is now stale in one respect: `vikunja-notify-relay` no longer runs on k3s either, so it can be dropped from that selector next time either policy is touched (left as-is here since it's harmless — an unmatched selector value, not a broken one).

**Same day, subsequently: phase F+G retired `placeholder-hello` outright**, replacing it with the two-tier `hello-frontend`/`hello-backend` app in the new `pr-lanes` namespace — see the "Istio Ambient / PR Lanes" section below. As of that phase, the k3s-native service list is `lab-environment`/`headlamp`/`pr-lanes`, not `lab-environment`/`headlamp`/`placeholder-hello` as stated in the paragraph above (kept as written for historical accuracy about that point in time). `require-vuln-scan-clean`'s and `restricted-self-built`'s `app in (...)` selectors were updated in the same move, from `placeholder-hello, vikunja-notify-relay` to `hello-frontend, hello-backend` — the selector values shown earlier in this section already reflect that current state, not the pre-phase-F+G one.

## Istio Ambient / PR Lanes

Phase F+G installs Istio in **Ambient** mode (sidecar-free: a per-node `ztunnel` DaemonSet handles L4, an on-demand `waypoint` Envoy proxy handles L7) plus the Gateway API standard CRDs, and repurposes the old single-tier `placeholder-hello` practice app into a two-tier `hello-frontend` → `hello-backend` pair living in a new `pr-lanes` namespace. The goal: ArgoCD's `ApplicationSet` PR generator spins up an isolated, header-routed "lane" of `hello-backend` per open PR, without cloning the whole environment per PR. Full rationale (why two tiers are required for east-west routing to mean anything at all, the shared-baseline-vs-namespace-per-PR tradeoff, the resource budget math) is in the [phase F+G design doc](../../docs/superpowers/specs/2026-08-18-k3s-phase-fg-mesh-pr-lanes-design.md).

**Installed as 4 separate ArgoCD Applications, not one multi-source Application:** `istio-base`, `istio-istiod`, `istio-cni`, `istio-ztunnel` (`argocd/apps/istio-*.yaml`), each a single Helm chart pulled from `istio-release.storage.googleapis.com/charts` plus its own values file under `istio/`. This is a deliberate deviation from the design doc's original single-multi-source-Application sketch, done to match every other Helm-backed component already in this repo (`argocd`, `sealed-secrets`, `kyverno`, `trivy-operator`) — one Application per Helm release. `sync-wave` orders them (`base` → `istiod` → `cni`/`ztunnel`) since each stage depends on CRDs/webhooks the previous one installs. Gateway API's CRDs are their own Application too (`argocd/apps/gateway-api.yaml`, standard channel, `v1.6.1`), installed first (`sync-wave: -4`) since both the waypoint `Gateway` and every `HTTPRoute` need those CRDs to exist before Istio itself comes up.

`placeholder-hello` has been **fully retired** — no Application, Deployment, Service, or CI workflow remains for it anywhere in the repo. `hello-frontend`/`hello-backend` are its sole successor (the frontend even reuses its old signed image — see `apps/hello/k8s/frontend-deployment.yaml`, and the "CI pipeline" section above for why that image can't be rebuilt any more).

**2026-08-19 measured (`kubectl top pods -n istio-system` / `-n pr-lanes`):** `istiod` 102Mi, `istio-cni` 30Mi, `ztunnel` 29Mi, `waypoint` 26Mi — all well under the design doc's resource budget. Host `swap` usage is 2.6Gi/4.0Gi (`free -h`), unchanged from before this install — the mesh didn't push the host into worse swap pressure.

### What's meshed, and why only `pr-lanes`

Only the `pr-lanes` namespace carries the `istio.io/dataplane-mode: ambient` label (`apps/hello/k8s/namespace.yaml`). Every other namespace — `lab-environment`, `headlamp`, cluster infra (`argocd`/`cilium`/`kyverno`/`trivy-system`/`sealed-secrets`) — is untouched by the mesh. This is deliberate blast-radius control, not a permanent "mesh is lab-only" stance: the design doc's stated plan is to onboard `workloads`-shaped services in a later batch once `pr-lanes` proves stable, since ztunnel's per-node L4 mTLS already runs cluster-wide regardless of which namespaces opt in to L7. (As of this writing there's no `workloads`-equivalent namespace left on k3s to onboard anyway — see the root README's k3s summary for what actually migrated back to compose the same day this phase shipped.)

### The waypoint / HTTPRoute mechanism

- `hello-frontend` (baseline only, always exactly one copy) is a plain nginx pod with **no waypoint** — it's the mesh-external entry point, exposed via NodePort `30083`. Its `default.conf` (`apps/hello/k8s/frontend-configmap.yaml`) proxies `/api` to `http://hello-backend.pr-lanes.svc.cluster.local/` — **note the trailing slash**. It's required for nginx to strip the `/api` prefix before forwarding, since the backend only serves `/`; without it every proxied request 404s. This was a real bug hit during rollout (fixed in commit `25ace1e`), not a style choice — don't drop it if this file gets touched again.
- The `hello-backend` Service carries `istio.io/use-waypoint: waypoint` (`backend-service.yaml`). Ambient's per-node `ztunnel` intercepts any request to that Service and diverts it to the waypoint Envoy instead of routing directly to a backend pod.
- The waypoint itself is a Gateway API `Gateway` (`waypoint-gateway.yaml`, `gatewayClassName: istio-waypoint`, one `HBONE`-protocol listener) — Istio provisions its Envoy Deployment from that resource.
- Routing rules are plain `HTTPRoute`s, all `parentRefs` pointing at the `hello-backend` **Service** (not a Gateway — the ambient convention for east-west routing): a static catch-all (`backend-httproute.yaml`, no match conditions → baseline `hello-backend`) plus one dynamically-generated route per PR lane (`header x-pr-lane: <N>` → `hello-backend-pr-<N>`). Gateway API's own rule-merge spec ranks header-match count above no-match, so a lane's route always outranks the catch-all — no manual priority juggling needed when a lane is added or removed.
- **`global.waypoint.resources` in `istio/istiod-values.yaml`** (`50m/128Mi` requests, `200m/256Mi` limits) is **not** in the original design doc text — it was added because the Istio chart's own default waypoint limits (`2` CPU / `1Gi` memory) exceed the entire `pr-lanes` `ResourceQuota` (`1200m`/`1536Mi` limits, total) on their own, and the waypoint pod couldn't schedule at all until this override went in. This is load-bearing, not cosmetic — don't remove it without re-sizing the quota to match.

### Opening a test PR

1. Branch, commit a change under `vps_oracle/k3s/apps/hello/backend/**`, open a PR against `main`.
2. **Add the `pr-lane` label to the PR on GitHub.** Without it: the ApplicationSet's `pullRequest.github` generator (`argocd/apps/pr-lanes-appset.yaml`, `requeueAfterSeconds: 30`) ignores the PR entirely (no lane gets generated), and CI's `build-scan-sign` job (`.github/workflows/hello-backend.yml`) skips the build outright (`if: github.event_name != 'pull_request' || contains(github.event.pull_request.labels.*.name, 'pr-lane')`) — the label gates both halves of the pipeline, not just the ArgoCD side.
3. CI builds, Trivy-scans, and Cosign-signs `hello-backend`, tagged with the **PR head SHA** (`github.event.pull_request.head.sha` — deliberately not `github.sha`, which under `pull_request` events is GitHub's auto-generated merge-commit SHA and won't match what the ApplicationSet's `{{.head_sha}}` resolves to).
4. Within ~30s of the label/push, the generator produces an ArgoCD Application named **`hello-pr-<N>`** (`N` = PR number), synced from the Kustomize base at `apps/hello/lane/` (JSON6902-patched per PR — name/labels/header-match/backendRef all rewritten to that PR's number) into the `pr-lanes` namespace, creating that lane's own `Deployment`/`Service`/`HTTPRoute` trio.
5. Test with `curl -H "x-pr-lane: <N>" http://<node-ip>:30083/api` (lane content) vs. plain `curl http://<node-ip>:30083/api` (baseline, unaffected — proves the shared baseline wasn't polluted).
6. Closing/merging the PR drops it from the generator's next poll; the `hello-pr-<N>` Application (its template carries `finalizers: [resources-finalizer.argocd.argoproj.io]`) is deleted and its 3 owned resources pruned with it.

Note: `kustomize.images` in `pr-lanes-appset.yaml` uses the **plain string form** (`- ghcr.io/jeromefromcn/hello-backend:{{.head_sha}}`), not the `[{name, newTag}]` object form. This cluster's ArgoCD (`v3.5.0`) CRD only accepts strings there — the object form is rejected at admission (`must be of type string`), which silently prevented the ApplicationSet from being created at all until this was caught and fixed (commit `4013dd1`).

### Rotating the GitHub PAT

The generator authenticates to GitHub via a fine-grained PAT, sealed into `sealed-secrets/secrets/github-pr-generator-token.sealed.yaml` (see "Sealed Secrets" above for the general pattern). Token creation itself can't be automated the way a `kubeseal` migration can — it's a manual step on github.com:

1. github.com → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.
2. Repository access: **Only** `Jeromefromcn/docker-gitops`. Permissions: **Pull requests: Read-only**, **Contents: Read-only** (the generator only lists/reads PRs, never writes anything). Expiration: your call — read-only, single-repo, low blast radius, but fine-grained PATs cap out at 1 year so this needs periodic repeating.
3. Reseal with the new value, **overwriting the existing file** (unlike a fresh migration, there's no old bare Secret to delete first — the controller already owns this Secret's name and updates it in place on the next sync):
   ```bash
   kubectl create secret generic github-pr-generator-token \
     --namespace argocd \
     --from-literal=token='<new PAT>' \
     --dry-run=client -o json \
     | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
     > vps_oracle/k3s/sealed-secrets/secrets/github-pr-generator-token.sealed.yaml
   ```
4. Verify no plaintext leaked before committing: `grep -q 'ghp_\|github_pat_' vps_oracle/k3s/sealed-secrets/secrets/github-pr-generator-token.sealed.yaml && echo STOP || echo OK`.
5. Commit, push. `kubectl -n argocd get applicationset pr-lanes -o jsonpath='{.status.conditions[?(@.type=="ResourcesUpToDate")].status}'` → `True` confirms the new token authenticates.

### Rollback path

The design doc's known-limitations section calls out Cilium/Istio-ambient CNI chaining as a combination with known community reports of `ztunnel` failing to start cleanly. If that happens and root cause isn't quickly obvious, rolling back beats prolonged debugging: remove the four `istio-*` Applications (`istio-base`/`istio-istiod`/`istio-cni`/`istio-ztunnel`) and drop `pr-lanes`'s `istio.io/dataplane-mode: ambient` namespace label. Cilium's `cni.exclusive: false` flag (`cilium/values.yaml`) is safe to leave set either way — it's a no-op for a pure-Cilium setup with no other chained CNI plugin present, so there's no need to revert it as part of the rollback.

One thing to know before deleting any of those four Application manifests: none of them — and in fact no static `Application` anywhere in this repo, not just these four — sets `resources-finalizer.argocd.argoproj.io`. Only the `pr-lanes` `ApplicationSet`'s generated-Application template does (that's what makes per-PR lanes clean up after themselves). Deleting a static Application's manifest orphans its managed resources instead of cascading their deletion, so expect to clean up the mesh's namespaced/cluster-scoped resources (CRDs, webhooks, DaemonSets) by hand after removing the Application objects, not have them vanish automatically. This is a pre-existing repo-wide gap, not something introduced by phase F+G.

## Handoff to phase C

Phase C (first real service migrations) picks up from here: a working GitOps loop (ArgoCD app-of-apps, `selfHeal`/`prune` on everything) and a proven CI pattern (`placeholder-hello.yml`) to copy for the first real service — same build→Trivy→Cosign→GHCR shape, just point it at a real Dockerfile and give the resulting Application its own entry under `argocd/apps/`. ArgoCD's UI is reachable at `https://argocd.jerome.cloudns.asia` (NPM, `self-only` access list) for watching syncs during migrations.

## Handoff to phase D

Phase C (homepage + trilium migrated) leaves phase D two reusable templates: `apps/homepage/` (config-as-code via ConfigMap + initContainer→emptyDir, for services that don't hold real data) and `apps/trilium/` (dynamically-provisioned PVC + one-off seed-Pod data migration, for services that do). Both follow the same shape: manifests under `apps/<service>/k8s/`, one child Application under `argocd/apps/`, a fixed NodePort, and an NPM proxy host repointed from the compose container to that NodePort via the automation API (`vps_oracle/compose/npm/.npm-automation.env` + `vps_oracle/compose/npm/README.md`) — domain unchanged throughout.

**Before starting phase D:** ~~the `workloads` ResourceQuota is close to its `limits.cpu` cap (`900m` used of `1`)~~ — raised 2026-08-10 to `2`/`4Gi` (see "Namespace & quota" above) after this ceiling got hit a second time (homepage's CCR-card rollout, same failure mode as trilium's). Re-check headroom before phase D's bigger services (dify, vikunja+pg, the llm stack) land — `2` cores was sized for "a few more homepage/trilium-sized services," not yet for those.

**Two gotchas found during phase C worth checking on every future migration, not just trilium's:**
- If a Service's name matches a prefix the app's own image reads as a config env var (e.g. `trilium` Service → `TRILIUM_PORT`), Kubernetes' auto-injected `<SVCNAME>_PORT`/`<SVCNAME>_SERVICE_HOST` variables silently collide with it. Set `enableServiceLinks: false` on the pod spec, or check the app's env-var-derived config names against the Service name before naming it.
- `local-path-provisioner`'s PV type is `local` (`spec.local.path`), not `hostPath` — don't assume `spec.hostPath.path` when scripting against a PV it created.

Phase D's services introduce problems phase C deliberately didn't cover: multi-container stacks with inter-service dependencies (dify), database services where StatefulSet-vs-Deployment actually matters (vikunja+pg), the llm stack's much larger CPU/memory footprint, and 3x-ui's raw TCP passthrough on `39876` (can't go through an HTTP reverse proxy at all — see the roadmap's 現狀約束).

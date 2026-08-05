# K3s Phase A — Cluster Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a single-node k3s cluster with Cilium CNI, prove NPM can reach a workload inside it (and that NetworkPolicy actually blocks traffic), then tear the workload back down so the cluster ends the phase empty but production-ready.

**Architecture:** k3s (own embedded containerd, kube-proxy disabled) + Cilium (kube-proxy replacement, VXLAN, Hubble relay+UI) on the single Oracle VPS host, alongside — not replacing — the existing docker compose stacks. NPM (docker) reaches into the cluster via `extra_hosts: host-gateway` to a fixed NodePort, never by joining the cluster's own network.

**Tech Stack:** k3s, Cilium (Helm), Hubble, kubectl, Nginx Proxy Manager (existing), bash

**Reference spec:** [docs/superpowers/specs/2026-08-05-k3s-phase-a-cluster-foundation-design.md](../specs/2026-08-05-k3s-phase-a-cluster-foundation-design.md)

## Global Constraints

- Single-node k3s, server role, no HA — this host is the only node.
- k3s install disables: `traefik`, `servicelb`, and kube-proxy (`disable-kube-proxy: true`) — Cilium's kube-proxy replacement takes over service routing entirely; `flannel-backend: none` since Cilium is the CNI.
- Cilium: `kubeProxyReplacement: true`, tunnel mode left at chart default (VXLAN), `hubble.relay.enabled: true`, `hubble.ui.enabled: true`.
- local-path-provisioner stays enabled at k3s's default path `/var/lib/rancher/k3s/storage` — do not relocate it.
- No hardcoded version numbers in committed config — every install step looks up the current stable/latest release at run time and records the resolved version into `vps_oracle/k3s/README.md`.
- No secrets in the repo: kubeconfig, node token, and any Cilium-generated certs stay under `/etc/rancher/k3s/` and `/var/lib/rancher/k3s/`, never under `vps_oracle/k3s/`.
- `workloads` namespace ResourceQuota: `requests.cpu: "1"`, `requests.memory: 2Gi`, `limits.cpu: "1"`, `limits.memory: 2Gi`. LimitRange per-container `defaultRequest: cpu 100m / memory 128Mi`, `default: cpu 200m / memory 256Mi`.
- Image tags pinned, never `latest` (repo-wide convention, see `CLAUDE.md`).
- NPM's own compose file and network membership do not change beyond adding `extra_hosts` — no other edits to `vps_oracle/compose/npm/`.
- Smoke-test NodePort is fixed at `30080`, not dynamically assigned.
- After verification passes, the cluster must be returned to empty (smoke-test workloads, NetworkPolicy, and the temporary NPM proxy host all removed) but `vps_oracle/k3s/manifests/smoke-test.yaml` stays committed for reuse in later phases.

---

## File Structure

```
vps_oracle/k3s/
  README.md              # install steps, resolved version table, verification runbook
  install/
    config.yaml            # k3s server config (copied to /etc/rancher/k3s/config.yaml)
  cilium/
    values.yaml             # Helm values for the cilium/cilium chart
  manifests/
    namespace.yaml           # workloads Namespace
    resourcequota.yaml        # workloads-quota
    limitrange.yaml            # workloads-limits
    smoke-test.yaml             # Deployment + Service + tester Pod + NetworkPolicy, reusable
```

Modified outside `vps_oracle/k3s/`:
- `vps_oracle/compose/npm/docker-compose.yml` — add `extra_hosts` for the host-gateway bridge.

---

### Task 1: Install k3s (CNI-less, kube-proxy disabled) and check it into the repo

**Files:**
- Create: `vps_oracle/k3s/install/config.yaml`
- Create: `vps_oracle/k3s/README.md`

**Interfaces:**
- Produces: a running (but `NotReady`, no CNI yet) k3s server at `/etc/rancher/k3s/`, and `~/.kube/config` usable by the `ubuntu` user without `sudo`. Task 2 depends on this node existing.

- [ ] **Step 1: Write the k3s server config**

Create `vps_oracle/k3s/install/config.yaml`:

```yaml
disable:
  - traefik
  - servicelb
flannel-backend: none
disable-network-policy: true
disable-kube-proxy: true
write-kubeconfig-mode: "0600"
```

- [ ] **Step 2: Look up the current k3s stable release**

```bash
K3S_VERSION=$(curl -s https://api.github.com/repos/k3s-io/k3s/releases | jq -r '[.[] | select(.prerelease==false)][0].tag_name')
echo "$K3S_VERSION"
```

Expected: prints a version string like `v1.31.x+k3s1` (exact number will differ from this plan's authoring date — that's expected, not an error).

- [ ] **Step 3: Copy the config into place and install k3s pinned to that version**

```bash
sudo mkdir -p /etc/rancher/k3s
sudo cp vps_oracle/k3s/install/config.yaml /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
```

- [ ] **Step 4: Set up kubectl access for the `ubuntu` user**

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown ubuntu:ubuntu ~/.kube/config
chmod 600 ~/.kube/config
```

- [ ] **Step 5: Verify the node registered**

```bash
kubectl get nodes -o wide
```

Expected: one node listed, `STATUS` is `NotReady` (this is correct — there's no CNI yet, kubelet won't flip to `Ready` until Task 2 installs Cilium). If the command errors with "connection refused", check `sudo systemctl status k3s` for the install failing.

- [ ] **Step 6: Start `vps_oracle/k3s/README.md` with the resolved version**

Create `vps_oracle/k3s/README.md`:

```markdown
# vps_oracle/k3s

Phase A cluster foundation for the [K3s roadmap](../../docs/superpowers/specs/2026-08-05-k3s-cloud-native-platform-roadmap.md). See the [phase A design doc](../../docs/superpowers/specs/2026-08-05-k3s-phase-a-cluster-foundation-design.md) for the full rationale.

## Installed versions

| Component | Version | Resolved on |
|---|---|---|
| k3s | `<K3S_VERSION from Task 1 Step 2>` | <today's date> |

## Install

1. `sudo cp install/config.yaml /etc/rancher/k3s/config.yaml`
2. `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="<pinned version>" sh -`
3. `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown ubuntu:ubuntu ~/.kube/config && chmod 600 ~/.kube/config`

Re-applying `install/config.yaml` after an edit: copy it to `/etc/rancher/k3s/config.yaml` again, then `sudo systemctl restart k3s`.
```

Replace `<K3S_VERSION from Task 1 Step 2>` and `<today's date>` with the actual values printed in Step 2.

- [ ] **Step 7: Commit**

```bash
git add vps_oracle/k3s/install/config.yaml vps_oracle/k3s/README.md
git commit -m "Install k3s single-node (Cilium-pending) for roadmap phase A"
```

---

### Task 2: Install Cilium (kube-proxy replacement, Hubble relay + UI)

**Files:**
- Create: `vps_oracle/k3s/cilium/values.yaml`
- Modify: `vps_oracle/k3s/README.md` (append Cilium version to the version table, add Cilium section)

**Interfaces:**
- Consumes: the k3s node from Task 1 (`kubectl` working, node `NotReady`).
- Produces: `Ready` node, working Service routing (Cilium replacing kube-proxy), Hubble relay + UI reachable via `kubectl port-forward`. Task 3 depends on the node being `Ready` and the `workloads` namespace being schedulable.

- [ ] **Step 1: Install Helm and add the Cilium repo**

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add cilium https://helm.cilium.io/
helm repo update
```

- [ ] **Step 2: Look up the current Cilium chart version**

```bash
CILIUM_CHART_VERSION=$(helm search repo cilium/cilium -o json | jq -r '.[0].version')
echo "$CILIUM_CHART_VERSION"
```

Expected: prints a version string like `1.16.x`.

- [ ] **Step 3: Write the Helm values file**

Create `vps_oracle/k3s/cilium/values.yaml`:

```yaml
kubeProxyReplacement: true
k8sServiceHost: 127.0.0.1
k8sServicePort: 6443
operator:
  replicas: 1
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
```

- [ ] **Step 4: Install Cilium**

```bash
helm install cilium cilium/cilium \
  --version "$CILIUM_CHART_VERSION" \
  --namespace kube-system \
  -f vps_oracle/k3s/cilium/values.yaml
```

- [ ] **Step 5: Wait for rollout and confirm the node goes Ready**

```bash
kubectl -n kube-system rollout status daemonset/cilium --timeout=180s
kubectl get nodes
```

Expected: rollout succeeds, node `STATUS` is now `Ready`.

- [ ] **Step 6: Install the `cilium` and `hubble` CLIs, pinned to their current stable releases**

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"
sudo tar xzvf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
rm "cilium-linux-${CLI_ARCH}.tar.gz"

HUBBLE_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --fail --remote-name-all "https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-linux-${CLI_ARCH}.tar.gz"
sudo tar xzvf "hubble-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
rm "hubble-linux-${CLI_ARCH}.tar.gz"
```

- [ ] **Step 7: Verify Cilium status and kube-proxy replacement**

```bash
cilium status --wait
```

Expected: all components `OK`, and the output includes a line `KubeProxyReplacement: True`. If it shows `False` or `Disabled`, re-check `vps_oracle/k3s/cilium/values.yaml` was actually applied (`helm get values cilium -n kube-system`) and that Task 1's `disable-kube-proxy: true` took effect (`kubectl -n kube-system get pods -l k8s-app=kube-proxy` should return no resources).

- [ ] **Step 8: Verify Hubble is reachable**

```bash
kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
sleep 2
hubble status --server localhost:4245
kill %1
```

Expected: `hubble status` reports `Healthcheck (via localhost:4245): Ok`.

- [ ] **Step 9: Record the Cilium version and add a Cilium section to the README**

Edit `vps_oracle/k3s/README.md`, add a row to the version table and a section:

```markdown
| Cilium | `<CILIUM_CHART_VERSION from Task 2 Step 2>` | <today's date> |
```

```markdown
## Cilium

Installed via Helm with `kube-proxy-replacement: true` — k3s's own kube-proxy is disabled (see `install/config.yaml`). Hubble relay + UI are enabled for flow observability.

Reinstall/upgrade: `helm upgrade cilium cilium/cilium --version <pinned> --namespace kube-system -f cilium/values.yaml`

Check health: `cilium status --wait`. View flows: `kubectl -n kube-system port-forward svc/hubble-ui 12000:80`, then open `http://localhost:12000` through an SSH tunnel.
```

- [ ] **Step 10: Commit**

```bash
git add vps_oracle/k3s/cilium/values.yaml vps_oracle/k3s/README.md
git commit -m "Install Cilium with kube-proxy replacement and Hubble for phase A"
```

---

### Task 3: Create the `workloads` namespace with ResourceQuota and LimitRange

**Files:**
- Create: `vps_oracle/k3s/manifests/namespace.yaml`
- Create: `vps_oracle/k3s/manifests/resourcequota.yaml`
- Create: `vps_oracle/k3s/manifests/limitrange.yaml`

**Interfaces:**
- Consumes: `Ready` node from Task 2.
- Produces: `workloads` namespace with quota/limits enforced. Task 4 deploys into this namespace.

- [ ] **Step 1: Write the namespace manifest**

Create `vps_oracle/k3s/manifests/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: workloads
```

- [ ] **Step 2: Write the ResourceQuota manifest**

Create `vps_oracle/k3s/manifests/resourcequota.yaml`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: workloads-quota
  namespace: workloads
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 2Gi
    limits.cpu: "1"
    limits.memory: 2Gi
```

- [ ] **Step 3: Write the LimitRange manifest**

Create `vps_oracle/k3s/manifests/limitrange.yaml`:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: workloads-limits
  namespace: workloads
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      default:
        cpu: 200m
        memory: 256Mi
```

- [ ] **Step 4: Apply all three**

```bash
kubectl apply -f vps_oracle/k3s/manifests/namespace.yaml
kubectl apply -f vps_oracle/k3s/manifests/resourcequota.yaml
kubectl apply -f vps_oracle/k3s/manifests/limitrange.yaml
```

- [ ] **Step 5: Verify quota and limits are live**

```bash
kubectl describe resourcequota workloads-quota -n workloads
kubectl describe limitrange workloads-limits -n workloads
```

Expected: `resourcequota` shows `Used` all zero, `Hard` matching the values above. `limitrange` shows the container default/defaultRequest rows.

- [ ] **Step 6: Commit**

```bash
git add vps_oracle/k3s/manifests/namespace.yaml vps_oracle/k3s/manifests/resourcequota.yaml vps_oracle/k3s/manifests/limitrange.yaml
git commit -m "Add workloads namespace with ResourceQuota and LimitRange"
```

---

### Task 4: Smoke-test workload — deploy, curl the NodePort

**Files:**
- Create: `vps_oracle/k3s/manifests/smoke-test.yaml`

**Interfaces:**
- Consumes: `workloads` namespace from Task 3.
- Produces: a running nginx pod reachable at `http://<host>:30080`. Task 5 adds the NetworkPolicy and tester pod to this same file. Task 6 curls this NodePort from NPM.

- [ ] **Step 1: Write the Deployment and Service**

Create `vps_oracle/k3s/manifests/smoke-test.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke-test
  namespace: workloads
  labels:
    app: smoke-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: smoke-test
  template:
    metadata:
      labels:
        app: smoke-test
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: smoke-test
  namespace: workloads
spec:
  type: NodePort
  selector:
    app: smoke-test
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
```

- [ ] **Step 2: Apply and wait for the pod to be ready**

```bash
kubectl apply -f vps_oracle/k3s/manifests/smoke-test.yaml
kubectl -n workloads rollout status deployment/smoke-test --timeout=60s
```

Expected: `deployment "smoke-test" successfully rolled out`.

- [ ] **Step 3: Curl the NodePort from the host**

```bash
curl -sS http://localhost:30080 | head -5
```

Expected: nginx's default welcome HTML (`<!DOCTYPE html>` ... `Welcome to nginx!`).

- [ ] **Step 4: Confirm the quota now shows usage**

```bash
kubectl describe resourcequota workloads-quota -n workloads
```

Expected: `Used` shows `requests.cpu: 50m`, `requests.memory: 64Mi`, `limits.cpu: 100m`, `limits.memory: 128Mi`.

- [ ] **Step 5: Commit**

```bash
git add vps_oracle/k3s/manifests/smoke-test.yaml
git commit -m "Add smoke-test workload for phase A connectivity verification"
```

---

### Task 5: NetworkPolicy enforcement test

**Files:**
- Modify: `vps_oracle/k3s/manifests/smoke-test.yaml` (append tester Pod and NetworkPolicy)

**Interfaces:**
- Consumes: `smoke-test` Deployment/Service from Task 4.
- Produces: proof that Cilium enforces `NetworkPolicy`, not just base connectivity — this is the roadmap's explicit "CNI/NetworkPolicy" requirement for phase A.

- [ ] **Step 1: Append a tester pod to the manifest**

Add to `vps_oracle/k3s/manifests/smoke-test.yaml` (new `---` document):

```yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: netpol-tester
  namespace: workloads
  labels:
    app: netpol-tester
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
```

- [ ] **Step 2: Apply and confirm traffic works before any policy exists**

```bash
kubectl apply -f vps_oracle/k3s/manifests/smoke-test.yaml
kubectl -n workloads wait --for=condition=Ready pod/netpol-tester --timeout=60s
kubectl -n workloads exec netpol-tester -- wget -qO- --timeout=3 http://smoke-test.workloads.svc.cluster.local | head -3
```

Expected: nginx welcome HTML — confirms baseline pod-to-pod connectivity before the policy is applied (a negative NetworkPolicy test only proves something if you know the traffic worked beforehand).

- [ ] **Step 3: Append the deny-all NetworkPolicy to the same manifest**

Add to `vps_oracle/k3s/manifests/smoke-test.yaml` (new `---` document):

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: workloads
spec:
  podSelector:
    matchLabels:
      app: smoke-test
  policyTypes:
    - Ingress
```

- [ ] **Step 4: Apply and confirm traffic is now blocked**

```bash
kubectl apply -f vps_oracle/k3s/manifests/smoke-test.yaml
kubectl -n workloads exec netpol-tester -- wget -qO- --timeout=3 http://smoke-test.workloads.svc.cluster.local
```

Expected: command fails with a timeout (`wget: download timed out`), non-zero exit code. This proves Cilium is actually enforcing `NetworkPolicy`, not just routing traffic.

- [ ] **Step 5: Confirm the NodePort path (host → pod, bypasses the Service-to-Service path tested above) is unaffected**

```bash
curl -sS --max-time 3 http://localhost:30080 | head -3
```

Expected: still returns nginx welcome HTML — the deny-all policy only blocks `Ingress` from other pods matching the selector's namespace-scoped rules as written; external/NodePort traffic into the pod is a separate check worth confirming didn't accidentally also break, since Task 6 depends on this path.

- [ ] **Step 6: Commit**

```bash
git add vps_oracle/k3s/manifests/smoke-test.yaml
git commit -m "Add NetworkPolicy enforcement test to smoke-test manifest"
```

---

### Task 6: NPM bridge, end-to-end verification, and cleanup

**Files:**
- Modify: `vps_oracle/compose/npm/docker-compose.yml`

**Interfaces:**
- Consumes: `smoke-test` Service NodePort 30080 from Task 4, `netpol-tester`/NetworkPolicy from Task 5.
- Produces: proof of `Internet → npm → host:30080 → k3s pod`, then tears the smoke-test resources and temporary NPM config back down so the cluster ends the phase empty, per the spec's stated deliverable.

- [ ] **Step 1: Add the host-gateway bridge to NPM**

Edit `vps_oracle/compose/npm/docker-compose.yml`, add under the `app` service (alongside the existing `environment:`/`volumes:`/`networks:` keys):

```yaml
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

- [ ] **Step 2: Apply the compose change**

```bash
cd vps_oracle/compose/npm && docker compose up -d
```

Expected: compose recreates only the `npm` container (config hash changed because `extra_hosts` was added); confirm with `docker inspect npm --format '{{.HostConfig.ExtraHosts}}'` showing `host.docker.internal:host-gateway`.

- [ ] **Step 3: Confirm the container can resolve and reach the NodePort**

```bash
docker exec npm getent hosts host.docker.internal
docker exec npm wget -qO- --timeout=3 http://host.docker.internal:30080 | head -3
```

Expected: `getent` prints the host gateway IP; `wget` prints the nginx welcome HTML — proves the bridge works before touching the NPM UI.

- [ ] **Step 4: Create a temporary NPM proxy host**

In the NPM UI (`https://npm.jerome.cloudns.asia`), per README's "给服务接入 NPM 反代" conventions but deliberately without SSL (this proxy host is deleted at the end of this task, so requesting a Let's Encrypt cert for it would be wasted issuance):

| Field | Value |
|---|---|
| Domain Names | `k3s-smoketest.jerome.cloudns.asia` |
| Scheme | `http` |
| Forward Hostname / IP | `host.docker.internal` |
| Forward Port | `30080` |
| Cache Assets | off |
| Block Common Exploits | on |
| Websockets Support | on |
| Access List | `self-only` |
| SSL | skip — leave unset, do not request a certificate |

Save the proxy host.

- [ ] **Step 5: Verify end-to-end from outside**

```bash
curl -sS http://k3s-smoketest.jerome.cloudns.asia | head -5
```

Expected: nginx welcome HTML — this is the spec's actual "NPM 能打進來" deliverable, confirmed over the real domain, not just `localhost`.

- [ ] **Step 6: Tear down the smoke-test workload and NetworkPolicy**

```bash
kubectl delete -f vps_oracle/k3s/manifests/smoke-test.yaml
kubectl get pods -n workloads
```

Expected: `No resources found in workloads namespace.` — the manifest file itself stays committed in the repo (per the spec, it's a reusable verification tool for later phases); only the live resources are deleted.

- [ ] **Step 7: Delete the temporary NPM proxy host**

In the NPM UI, delete the `k3s-smoketest.jerome.cloudns.asia` proxy host created in Step 4.

Confirm:
```bash
curl -sS --max-time 3 http://k3s-smoketest.jerome.cloudns.asia
```
Expected: connection failure (DNS still resolves if wildcarded, but NPM no longer has a matching host — expect a TLS/connection error or NPM's default "no host" response, not the nginx welcome page).

- [ ] **Step 8: Confirm the cluster is otherwise untouched**

```bash
kubectl get nodes
cilium status
kubectl get namespaces
kubectl get resourcequota,limitrange -n workloads
```

Expected: node `Ready`, Cilium healthy, `workloads` namespace still exists with its quota/limitrange (those are infrastructure, not the "empty" part — only the smoke-test workload was meant to be torn down), no leftover pods/services in `workloads`.

- [ ] **Step 9: Commit**

```bash
git add vps_oracle/compose/npm/docker-compose.yml
git commit -m "Bridge NPM to k3s NodePorts via host-gateway extra_hosts"
```

---

## Self-Review Notes

- **Spec coverage:** every item in the phase A design's "驗證清單" (1–8) maps to a task step: node Ready (Task 1/2), `cilium status --wait` + KubeProxyReplacement (Task 2 Step 7), Hubble reachable (Task 2 Step 8), quota/limitrange enforced (Task 3 Step 5, Task 4 Step 4), NodePort curl (Task 4 Step 3), NetworkPolicy enforcement (Task 5), end-to-end via NPM (Task 6 Step 5), cleanup back to empty (Task 6 Steps 6–8).
- **Placeholder scan:** the only bracketed values left (`<K3S_VERSION from Task 1 Step 2>`, `<CILIUM_CHART_VERSION from Task 2 Step 2>`, `<pinned version>`, `<today's date>`) are explicitly instructed to be replaced with real values produced by the preceding step in the same task — not unresolved TBDs.
- **Type/name consistency:** `workloads` namespace, `smoke-test` Deployment/Service names, `netpol-tester` pod name, and NodePort `30080` are used identically across Tasks 3–6.

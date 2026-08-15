# K3s Phase E — Sealed Secrets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four bring-your-own, out-of-band Secrets left over from phase D (`workloads/vikunja`, `dify/dify-secrets`, `llm/open-webui`, `llm/sillytavern`) with `SealedSecret` resources committed to git, decrypted in-cluster by a Sealed Secrets controller — so ArgoCD manages them like everything else and a lost/deleted Secret can be reconstructed from git.

**Architecture:** Deploy the `bitnami-labs/sealed-secrets` controller via ArgoCD into its own `sealed-secrets` namespace. Use the `kubeseal` CLI to re-encrypt each existing live Secret into a `SealedSecret` manifest, commit it, delete the old bare Secret, and let the controller materialize the replacement. Back up the controller's signing key to an out-of-cluster location before touching any live secret, since it's the only decryption path on a single-node cluster with no etcd HA.

**Tech Stack:** Helm (`sealed-secrets/sealed-secrets` chart v2.19.1, app v0.38.4), `kubeseal` CLI v0.38.4 (linux-arm64), ArgoCD (existing), `kubectl`, `gpg` (symmetric, for key backup).

**Spec:** [docs/superpowers/specs/2026-08-15-k3s-phase-e-supply-chain-security-design.md](../specs/2026-08-15-k3s-phase-e-supply-chain-security-design.md)

## Global Constraints

- Pin image tags/digests. No `latest` (repo-wide rule, README.md).
- Never commit secrets or plaintext values — every command that touches a live Secret's data must pipe directly between `kubectl`/`jq`/`kubeseal` without echoing plaintext to the terminal or a file.
- One change per commit, scoped to one compose/k8s stack (repo-wide rule).
- Chart: `sealed-secrets/sealed-secrets` version `2.19.1` (app `0.38.4`), repo `https://bitnami.github.io/sealed-secrets`.
- `kubeseal` CLI: `v0.38.4`, linux-arm64 (host is `aarch64`).
- Controller namespace: dedicated `sealed-secrets` (not `kube-system`, not co-located with workloads) — `fullnameOverride: sealed-secrets` so every `kubeseal` invocation can use explicit `--controller-name sealed-secrets --controller-namespace sealed-secrets` with no ambiguity.
- Existing four Secrets to migrate (namespace/name/keys, confirmed live on 2026-08-15):
  - `workloads/vikunja`: `VIKUNJA_SERVICE_SECRET`
  - `dify/dify-secrets`: `CELERY_BROKER_URL`, `DB_PASSWORD`, `INIT_PASSWORD`, `PGVECTOR_PASSWORD`, `REDIS_PASSWORD`, `SECRET_KEY`
  - `llm/open-webui`: `WEBUI_SECRET_KEY`
  - `llm/sillytavern`: `SILLYTAVERN_BASICAUTHUSER_PASSWORD`, `SILLYTAVERN_BASICAUTHUSER_USERNAME`
  - All four are `type: Opaque`.
- Repo path convention: `vps_oracle/k3s/sealed-secrets/` (controller values + secrets/) alongside `vps_oracle/k3s/argocd/apps/sealed-secrets.yaml` (the child Application), following the existing `argocd.yaml` multi-source pattern (chart source + values-ref source + manifests-path source).

---

### Task 1: Install `kubeseal` CLI

**Files:**
- None (installs a binary to `/usr/local/bin/kubeseal`, outside the repo)

**Interfaces:**
- Produces: a working `kubeseal` binary on `PATH`, used by every later task in this plan.

- [ ] **Step 1: Download the release archive and its published checksum**

```bash
cd /tmp
curl -sLO https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.38.4/kubeseal-0.38.4-linux-arm64.tar.gz
curl -sL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.38.4/sealed-secrets_0.38.4_checksums.txt -o checksums.txt
grep "kubeseal-0.38.4-linux-arm64.tar.gz" checksums.txt
```

Expected: prints `bcc40ac15e29a21c270e2be8c62af29d4b01b9111ae667723e4b6d8e4009228b  kubeseal-0.38.4-linux-arm64.tar.gz`.

- [ ] **Step 2: Verify the checksum matches before extracting**

```bash
cd /tmp
echo "bcc40ac15e29a21c270e2be8c62af29d4b01b9111ae667723e4b6d8e4009228b  kubeseal-0.38.4-linux-arm64.tar.gz" | sha256sum -c -
```

Expected: `kubeseal-0.38.4-linux-arm64.tar.gz: OK`. If it prints `FAILED`, stop — do not extract or install, re-download and re-check first.

- [ ] **Step 3: Extract and install**

```bash
cd /tmp
tar -xzf kubeseal-0.38.4-linux-arm64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm -f kubeseal-0.38.4-linux-arm64.tar.gz kubeseal checksums.txt
```

- [ ] **Step 4: Confirm the binary works**

```bash
kubeseal --version
```

Expected: prints `kubeseal version: v0.38.4` (or similar version string containing `0.38.4`).

No commit for this task — it only installs a local host binary, no repo files change.

---

### Task 2: Deploy the Sealed Secrets controller via ArgoCD

**Files:**
- Create: `vps_oracle/k3s/sealed-secrets/values.yaml`
- Create: `vps_oracle/k3s/sealed-secrets/secrets/README.md`
- Create: `vps_oracle/k3s/argocd/apps/sealed-secrets.yaml`

**Interfaces:**
- Produces: a running controller in namespace `sealed-secrets`, Service/Deployment named `sealed-secrets` (via `fullnameOverride`), reachable by `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets` from Task 3 onward.

- [ ] **Step 1: Write the Helm values file**

```yaml
# vps_oracle/k3s/sealed-secrets/values.yaml
fullnameOverride: sealed-secrets

replicaCount: 1

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

- [ ] **Step 2: Create the placeholder secrets directory**

```markdown
<!-- vps_oracle/k3s/sealed-secrets/secrets/README.md -->
# Sealed Secrets

`SealedSecret` manifests land here, one file per migrated Secret. Each
is safe to commit — the payload is encrypted with the cluster's
sealed-secrets public key and can only be decrypted by the controller
running in the `sealed-secrets` namespace.

Produced by `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets`,
never hand-written.
```

This file exists only so the `secrets/` directory is non-empty and present in git before the ArgoCD Application in Step 3 references it — real `SealedSecret` files get added in Tasks 4-7.

- [ ] **Step 3: Write the ArgoCD Application**

```yaml
# vps_oracle/k3s/argocd/apps/sealed-secrets.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://bitnami.github.io/sealed-secrets
      chart: sealed-secrets
      targetRevision: "2.19.1"
      helm:
        releaseName: sealed-secrets
        valueFiles:
          - $values/vps_oracle/k3s/sealed-secrets/values.yaml
    - repoURL: https://github.com/Jeromefromcn/docker-gitops.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/Jeromefromcn/docker-gitops.git
      targetRevision: main
      path: vps_oracle/k3s/sealed-secrets/secrets
  destination:
    server: https://kubernetes.default.svc
    namespace: sealed-secrets
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Validate YAML parses**

```bash
cd /home/ubuntu/jerome/docker-gitops
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/sealed-secrets/values.yaml')); print('values ok')"
python3 -c "import yaml; yaml.safe_load(open('vps_oracle/k3s/argocd/apps/sealed-secrets.yaml')); print('app ok')"
```

Expected: both print `ok`.

- [ ] **Step 5: Commit and push**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/sealed-secrets/values.yaml vps_oracle/k3s/sealed-secrets/secrets/README.md vps_oracle/k3s/argocd/apps/sealed-secrets.yaml
git commit -m "Deploy Sealed Secrets controller via ArgoCD"
git push origin main
```

- [ ] **Step 6: Wait for sync and verify the controller is healthy**

```bash
kubectl -n argocd get application sealed-secrets -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n sealed-secrets get pods
kubectl -n sealed-secrets get deployment sealed-secrets
```

Expected: `Synced Healthy`; the pod is `Running` with no restarts; the Deployment is named exactly `sealed-secrets` (confirms `fullnameOverride` took effect).

- [ ] **Step 7: Confirm `kubeseal` can reach the controller**

```bash
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --fetch-cert > /tmp/sealed-secrets-pub-cert.pem
head -c 200 /tmp/sealed-secrets-pub-cert.pem
```

Expected: prints the start of a `-----BEGIN CERTIFICATE-----` PEM block. Leave the file at `/tmp/sealed-secrets-pub-cert.pem` — Tasks 4-7 reuse it to seal offline without hitting the cluster each time (`kubeseal --cert /tmp/sealed-secrets-pub-cert.pem` is equivalent to `--controller-name/--controller-namespace` and works even if the cluster API is briefly unreachable).

---

### Task 3: Back up the controller's signing key

**Files:**
- None (writes to `/home/ubuntu/secrets-backup/`, outside every git repo)

**Interfaces:**
- Produces: an encrypted, out-of-cluster backup of the sealed-secrets signing key — the single point of failure this whole system rests on.

- [ ] **Step 1: Create the backup directory (host-only, not under any repo)**

```bash
mkdir -p /home/ubuntu/secrets-backup
chmod 700 /home/ubuntu/secrets-backup
```

- [ ] **Step 2: Export the active signing key**

```bash
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > /tmp/sealed-secrets-key-raw.yaml
grep -c "^kind: Secret" /tmp/sealed-secrets-key-raw.yaml
```

Expected: the count is `1` (exactly one active key on a freshly installed controller — if it's more than 1, a key rotation already happened; back up all of them, the file already contains the full list either way).

- [ ] **Step 3: Encrypt the export with a passphrase (symmetric GPG, no keyring setup needed)**

```bash
gpg --symmetric --cipher-algo AES256 --output /home/ubuntu/secrets-backup/sealed-secrets-key-$(date +%Y%m%d).yaml.gpg /tmp/sealed-secrets-key-raw.yaml
```

This prompts interactively for a passphrase (twice, to confirm) — **use a passphrase you can actually recall or store in a password manager; there is no recovery if it's lost.** Do not pass the passphrase as a command-line argument (it would leak into shell history).

- [ ] **Step 4: Wipe the plaintext export**

```bash
shred -u /tmp/sealed-secrets-key-raw.yaml
```

- [ ] **Step 5: Verify the encrypted backup decrypts correctly**

```bash
gpg --decrypt /home/ubuntu/secrets-backup/sealed-secrets-key-$(date +%Y%m%d).yaml.gpg 2>/dev/null | grep -c "^kind: Secret"
```

Expected: prompts for the passphrase you just set, then prints `1` (or however many keys were in Step 2's count). This proves the backup is actually restorable, not just written.

- [ ] **Step 6: Manual follow-up (not automatable from this session)**

Copy `/home/ubuntu/secrets-backup/sealed-secrets-key-<date>.yaml.gpg` to storage physically separate from this VPS (personal machine, password manager attachment, etc.) — a copy that only lives on the same disk as the cluster it protects defeats the purpose. This step has to be done by hand outside this session; note it as done once completed.

No commit for this task — nothing here belongs in git.

---

### Task 4: Migrate `workloads/vikunja`

**Files:**
- Create: `vps_oracle/k3s/sealed-secrets/secrets/vikunja.sealed.yaml`

**Interfaces:**
- Consumes: `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets` from Task 2.
- Produces: a `SealedSecret` that the controller unseals into a `Secret` named `vikunja` in namespace `workloads`, matching what `vps_oracle/k3s/apps/vikunja/k8s/deployment.yaml:40-43` already references via `secretKeyRef`.

- [ ] **Step 1: Seal the live Secret, stripping server-assigned metadata, without printing plaintext**

```bash
kubectl get secret vikunja -n workloads -o json \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations, .status)' \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  > vps_oracle/k3s/sealed-secrets/secrets/vikunja.sealed.yaml
```

- [ ] **Step 2: Confirm the output has the right shape without printing secret data**

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('vps_oracle/k3s/sealed-secrets/secrets/vikunja.sealed.yaml'))
assert d['kind'] == 'SealedSecret'
assert d['metadata']['name'] == 'vikunja'
assert d['metadata']['namespace'] == 'workloads'
assert set(d['spec']['encryptedData'].keys()) == {'VIKUNJA_SERVICE_SECRET'}
print('shape ok')
"
```

Expected: prints `shape ok`. If any assertion fails, do not proceed — re-run Step 1 and check `kubectl get secret vikunja -n workloads -o jsonpath='{.data}'` for the actual key set.

- [ ] **Step 3: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/sealed-secrets/secrets/vikunja.sealed.yaml
git commit -m "Migrate workloads/vikunja Secret to SealedSecret"
git push origin main
```

- [ ] **Step 4: Delete the old bare Secret, then let ArgoCD materialize the sealed replacement**

```bash
kubectl delete secret vikunja -n workloads
kubectl -n argocd app sync sealed-secrets 2>/dev/null || true
```

If `argocd` CLI isn't available, skip the second command — the Application has `selfHeal: true` and will pick up the new file within its normal reconcile interval (tens of seconds); just wait instead of forcing sync.

- [ ] **Step 5: Verify the Secret came back with the right key**

```bash
kubectl get secret vikunja -n workloads -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
kubectl get secret vikunja -n workloads -o jsonpath='{.data.VIKUNJA_SERVICE_SECRET}' | wc -c
```

Expected: first command prints `SealedSecret` (proves the controller now owns it, not a leftover manual Secret); second command prints a non-zero byte count (the base64-encoded value is present).

- [ ] **Step 6: Confirm vikunja still starts cleanly against the resealed secret**

```bash
kubectl rollout restart deployment vikunja -n workloads
kubectl rollout status deployment vikunja -n workloads --timeout=60s
```

Expected: rollout completes successfully (`deployment "vikunja" successfully rolled out`), no `CrashLoopBackOff`.

---

### Task 5: Migrate `dify/dify-secrets`

**Files:**
- Create: `vps_oracle/k3s/sealed-secrets/secrets/dify-secrets.sealed.yaml`

**Interfaces:**
- Consumes: same `kubeseal` invocation pattern as Task 4.
- Produces: a `SealedSecret` unsealing into `Secret` `dify-secrets` in namespace `dify`, consumed via `secretKeyRef` across `db-postgres.yaml`, `api.yaml`, `pgvector.yaml`, `plugin-daemon.yaml`, `redis.yaml`, `worker.yaml`, `worker-beat.yaml`.

- [ ] **Step 1: Seal the live Secret**

```bash
kubectl get secret dify-secrets -n dify -o json \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations, .status)' \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  > vps_oracle/k3s/sealed-secrets/secrets/dify-secrets.sealed.yaml
```

- [ ] **Step 2: Confirm the output shape**

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('vps_oracle/k3s/sealed-secrets/secrets/dify-secrets.sealed.yaml'))
assert d['kind'] == 'SealedSecret'
assert d['metadata']['name'] == 'dify-secrets'
assert d['metadata']['namespace'] == 'dify'
expected = {'CELERY_BROKER_URL', 'DB_PASSWORD', 'INIT_PASSWORD', 'PGVECTOR_PASSWORD', 'REDIS_PASSWORD', 'SECRET_KEY'}
assert set(d['spec']['encryptedData'].keys()) == expected, set(d['spec']['encryptedData'].keys())
print('shape ok')
"
```

Expected: `shape ok`.

- [ ] **Step 3: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/sealed-secrets/secrets/dify-secrets.sealed.yaml
git commit -m "Migrate dify/dify-secrets Secret to SealedSecret"
git push origin main
```

- [ ] **Step 4: Delete the old bare Secret**

```bash
kubectl delete secret dify-secrets -n dify
```

Wait for ArgoCD's `selfHeal` reconcile (tens of seconds) or force-sync if the `argocd` CLI is available, same as Task 4 Step 4.

- [ ] **Step 5: Verify ownership and key presence**

```bash
kubectl get secret dify-secrets -n dify -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
kubectl get secret dify-secrets -n dify -o jsonpath='{.data}' | python3 -c "import json,sys; print(sorted(json.load(sys.stdin).keys()))"
```

Expected: `SealedSecret`; key list matches the six keys from Step 2.

- [ ] **Step 6: Confirm every dify component that reads this Secret restarts cleanly**

Dify has more pods than any other migrated service — restart them in dependency order (db/redis first, matching the phase D verification note "驗證要從底層往上"):

```bash
kubectl rollout restart statefulset db-postgres pgvector redis -n dify
kubectl rollout status statefulset db-postgres -n dify --timeout=90s
kubectl rollout status statefulset pgvector -n dify --timeout=90s
kubectl rollout status statefulset redis -n dify --timeout=90s

kubectl rollout restart deployment api worker worker-beat plugin-daemon web -n dify
kubectl rollout status deployment api -n dify --timeout=120s
kubectl rollout status deployment worker -n dify --timeout=120s
kubectl rollout status deployment worker-beat -n dify --timeout=120s
kubectl rollout status deployment plugin-daemon -n dify --timeout=120s
kubectl rollout status deployment web -n dify --timeout=120s
```

Expected: every rollout completes; `kubectl get pods -n dify` shows all `Running`, no `CrashLoopBackOff`.

- [ ] **Step 7: Functional check**

`curl http://localhost:<dify web NodePort>` and confirm the login page renders (same check as phase D's verification checklist item 4) — proves the resealed `SECRET_KEY`/`DB_PASSWORD`/etc. are actually working, not just present.

---

### Task 6: Migrate `llm/open-webui`

**Files:**
- Create: `vps_oracle/k3s/sealed-secrets/secrets/open-webui.sealed.yaml`

**Interfaces:**
- Consumes: same `kubeseal` pattern as Task 4.
- Produces: `SealedSecret` unsealing into `Secret` `open-webui` in namespace `llm`, consumed by `vps_oracle/k3s/apps/llm/k8s/open-webui.yaml:52`.

- [ ] **Step 1: Seal the live Secret**

```bash
kubectl get secret open-webui -n llm -o json \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations, .status)' \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  > vps_oracle/k3s/sealed-secrets/secrets/open-webui.sealed.yaml
```

- [ ] **Step 2: Confirm the output shape**

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('vps_oracle/k3s/sealed-secrets/secrets/open-webui.sealed.yaml'))
assert d['kind'] == 'SealedSecret'
assert d['metadata']['name'] == 'open-webui'
assert d['metadata']['namespace'] == 'llm'
assert set(d['spec']['encryptedData'].keys()) == {'WEBUI_SECRET_KEY'}
print('shape ok')
"
```

Expected: `shape ok`.

- [ ] **Step 3: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/sealed-secrets/secrets/open-webui.sealed.yaml
git commit -m "Migrate llm/open-webui Secret to SealedSecret"
git push origin main
```

- [ ] **Step 4: Delete the old bare Secret**

```bash
kubectl delete secret open-webui -n llm
```

Wait for reconcile as before.

- [ ] **Step 5: Verify and restart**

```bash
kubectl get secret open-webui -n llm -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
kubectl rollout restart deployment open-webui -n llm
kubectl rollout status deployment open-webui -n llm --timeout=60s
```

Expected: `SealedSecret`; rollout succeeds. (If `llm` is currently scaled to 0 per the runbook note in commit `b98894c`, `rollout status` will report immediately with 0/0 ready — that's expected; scale it to 1 first if you want a live functional check: `kubectl scale deployment open-webui -n llm --replicas=1`, verify, then scale back down.)

---

### Task 7: Migrate `llm/sillytavern`

**Files:**
- Create: `vps_oracle/k3s/sealed-secrets/secrets/sillytavern.sealed.yaml`

**Interfaces:**
- Consumes: same `kubeseal` pattern as Task 4.
- Produces: `SealedSecret` unsealing into `Secret` `sillytavern` in namespace `llm`, consumed by `vps_oracle/k3s/apps/llm/k8s/sillytavern.yaml:48,53`.

- [ ] **Step 1: Seal the live Secret**

```bash
kubectl get secret sillytavern -n llm -o json \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations, .status)' \
  | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  > vps_oracle/k3s/sealed-secrets/secrets/sillytavern.sealed.yaml
```

- [ ] **Step 2: Confirm the output shape**

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('vps_oracle/k3s/sealed-secrets/secrets/sillytavern.sealed.yaml'))
assert d['kind'] == 'SealedSecret'
assert d['metadata']['name'] == 'sillytavern'
assert d['metadata']['namespace'] == 'llm'
assert set(d['spec']['encryptedData'].keys()) == {'SILLYTAVERN_BASICAUTHUSER_PASSWORD', 'SILLYTAVERN_BASICAUTHUSER_USERNAME'}
print('shape ok')
"
```

Expected: `shape ok`.

- [ ] **Step 3: Commit**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/sealed-secrets/secrets/sillytavern.sealed.yaml
git commit -m "Migrate llm/sillytavern Secret to SealedSecret"
git push origin main
```

- [ ] **Step 4: Delete the old bare Secret**

```bash
kubectl delete secret sillytavern -n llm
```

Wait for reconcile as before.

- [ ] **Step 5: Verify and restart**

```bash
kubectl get secret sillytavern -n llm -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
kubectl rollout restart deployment sillytavern -n llm
kubectl rollout status deployment sillytavern -n llm --timeout=60s
```

Expected: `SealedSecret`; rollout succeeds (same 0-replica caveat as Task 6 Step 5 applies if `llm` is currently scaled down).

---

### Task 8: End-to-end resilience check

**Files:**
- None (verification only)

**Interfaces:**
- Consumes: all four `SealedSecret` files from Tasks 4-7.

- [ ] **Step 1: Confirm all four Secrets are now controller-owned**

```bash
for ns_name in "workloads vikunja" "dify dify-secrets" "llm open-webui" "llm sillytavern"; do
  set -- $ns_name
  owner=$(kubectl get secret "$2" -n "$1" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
  echo "$1/$2: $owner"
done
```

Expected: all four lines print `SealedSecret`.

- [ ] **Step 2: Prove the controller reconstructs a deleted Secret from git state alone (the actual point of this phase)**

```bash
kubectl delete secret vikunja -n workloads
sleep 15
kubectl get secret vikunja -n workloads -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
```

Expected: after the 15s wait, the Secret exists again with owner `SealedSecret` — reconstructed by the controller from the `SealedSecret` CR still in the cluster (not from git; the CR itself is the durable source, git is how it got there and how it survives a cluster rebuild).

- [ ] **Step 3: Confirm `kubectl -n argocd get applications` shows no regressions**

```bash
kubectl -n argocd get applications
```

Expected: every Application (including the 13 pre-existing ones plus the new `sealed-secrets`) is `Synced` + `Healthy`.

- [ ] **Step 4: Update the k3s README handoff section**

Add a short "Sealed Secrets" entry to `vps_oracle/k3s/README.md` (follow the existing `## ArgoCD` section's structure) noting: chart version installed, namespace, and the one-line kubeseal command pattern for adding a new secret in the future (so the next person migrating a new service's Secret doesn't have to re-derive Task 4's `kubectl | jq | kubeseal` pipeline from scratch).

- [ ] **Step 5: Commit the README update**

```bash
cd /home/ubuntu/jerome/docker-gitops
git add vps_oracle/k3s/README.md
git commit -m "Document Sealed Secrets in k3s README"
git push origin main
```

## Self-Review

- **Spec coverage**: 「裝 Sealed Secrets controller」→ Task 2；「私鑰備份」→ Task 3；4 個既有 Secret 遷移 → Task 4-7；「刪掉其中一個 Secret 確認自動重建」驗證清單第 3 條 → Task 8 Step 2；驗證清單第 1/2 條（Application Synced/Healthy、內容與遷移前一致）→ Task 2 Step 6、Task 4-7 各自 Step 2/5。
- **Placeholder scan**：無 TBD；每個 kubeseal/kubectl/gpg 指令都是可直接執行的實際內容；README 更新（Task 8 Step 4）指定了具體要寫什麼（版本、namespace、指令 pattern），不是空泛的「補文件」。
- **Type consistency**：`--controller-name sealed-secrets --controller-namespace sealed-secrets` 這組 flag 從 Task 2 Step 7 到 Task 7 全程一致；四個 Secret 的 key 集合（Task 4-7 各自 Step 2 的 assert）跟 Global Constraints 表列一致，來源是 2026-08-15 對活叢集的實測，不是憑印象。

---

Plan complete and saved to `docs/superpowers/plans/2026-08-15-k3s-phase-e-sealed-secrets.md`.

# Incident record: trivy-operator scan concurrency config silently ignored, triggering IO PSI alerts (cilium self lock contention + all arm64 image scans failing)

Date: 2026-08-17
Status: Resolved (fixed the two misplaced Helm values layers, root-caused the arm64 scan failure; `skipInitContainers` was briefly thought to have fixed the cilium self lock contention, but later proved to be an incomplete upstream implementation that never took effect — the real fix was excluding the entire cilium DaemonSet from scanning, and even the first attempt at that put the chart values in the wrong layer again, before finally switching to labeling the live resource directly — confirmed stable for over 13 minutes with no recurrence). Four items remain open: the Kyverno validation blind spot, whether to upgrade `builtInTrivyServer`, whether some services should move back to compose, and the unexplained zero-scan on some dify/hubble-ui containers — see section 7.
Environment: vps_oracle, the same 4-core ARM (aarch64) / 23.4GB RAM host, k3s single-node cluster, trivy-operator (Helm chart `trivy-operator` 0.35.0, operator version 0.33.0, image `mirror.gcr.io/aquasec/trivy-operator:0.33.0` + scanner `mirror.gcr.io/aquasec/trivy:0.73.0`), GitOps source `github.com/Jeromefromcn/docker-gitops` (ArgoCD `automated: {prune:true, selfHeal:true}`).
Related docs: [2026-08-17-k3s-memory-overcommit-io-pressure.md](2026-08-17-k3s-memory-overcommit-io-pressure.md) (an earlier incident the same day, sharing the same `io_pressure_critical` alert rule; that one was caused by node memory overcommit, this one by trivy-operator's own config problem plus internal lock contention — two completely independent incidents that triggered the same alert).
This document: full record of the on-site data, the investigation chain (including the two Helm values layer mistakes I made and corrected myself), the root-cause chain, the remediation process and verification method, and three open follow-up decisions, for reuse.

---

## 1. Symptoms

The user received the Grafana alert again:

```
IO PSI 'full' above 15% for 2 minutes on vps_oracle (processes stalled on IO, load average will follow)
```

It used the same rule (`io_pressure_critical`) as the memory-overcommit incident earlier the same day, but that fix (raising the memory limits on jaeger/trivy) had already been live for nearly an hour, so in theory it should not have recurred — this pointed to a new, independent trigger.

## 2. On-site snapshot

### 2.1 Live PSI: already recovered, but avg300 shows it just happened

```
$ cat /proc/pressure/io
some avg10=0.00 avg60=0.84 avg300=8.16 total=3499161378
full avg10=0.00 avg60=0.63 avg300=6.15 total=1985975762
```

`avg10` is zero (calm right now), but `avg300` (the past 5 minutes) still shows a 6%+ residual — meaning the spike just ended, this is not a currently-active continuous alert, so we need to look back through history.

### 2.2 Pull PSI history via Prometheus, compare multiple spike waves

The cluster already has node-exporter + Prometheus (container `prometheus`, no exposed port, must `docker exec` into the container to query `localhost:9090`). Using `rate(node_pressure_io_stalled_seconds_total[2m])*100` to pull the `full` curve over the past 3 hours, at least 5 distinct spike waves were captured:

| Time (HKT) | Peak |
|---|---|
| 12:56–13:21 (25 min sustained) | ~25–30% |
| 13:40 | **77.9%** (highest of the day) |
| 13:48–13:49 | ~31–33% |
| 14:41–14:42 | ~10–11% |
| 14:59–15:01 | ~18–35% |

Not a single isolated spike, but a recurring pattern with irregular intervals — ruling out a "one-off event" and pointing toward a "periodic / event-driven recurring trigger".

### 2.3 Time correlation: every wave lines up with trivy scan pod creation

`journalctl` turned up `Observed pod startup duration`; filtering for `scan-vulnerabilityreport-*` pods in the `trivy-system` namespace, their startup times matched every spike wave precisely (13:20:45, 13:49:06×3, 14:41:33/14:42:18, 15:00:03×4/15:00:48/15:01:33). At the same time, the 3x-ui container logs on the `docker` side showed `database is locked` — initially thought to be an independent clue, but later confirmed to overlap in time with the trivy spikes, i.e. a **secondary symptom** where 3x-ui's own SQLite writes got stuck once trivy saturated the disk, not a separate problem.

## 3. Investigation chain

### 3.1 First misplaced Helm values layer (`scanJobsConcurrentLimit`)

Checked `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT` in the `trivy-operator-config` ConfigMap; the live value was **10**. But in git, `vps_oracle/k3s/trivy-operator/values.yaml` clearly says `scanJobsConcurrentLimit: 3`. Using `helm show values trivy-operator --repo https://aquasecurity.github.io/helm-charts/ --version 0.35.0` to compare against the official chart schema, it turned out the correct key must be nested under `operator:`, whereas the repo had placed it at the **top level** — Helm silently ignores unrecognized keys, so this setting never took effect and the chart's built-in default of 10 was actually applied.

10 concurrent scan jobs share the same local filesystem cache directory (`trivy.filesystemScanCacheDir`), which uses file locks and does not support concurrent access — searching the trivy-operator logs over 6 hours, `Failed to acquire cache or database lock ... cache may be in use by another process: timeout` appeared 36 times, with multiple `BackoffLimitExceeded` entries in the corresponding Job events (retries exhausted, giving up). Every failure had first fully pulled the image layer once before failing to acquire the lock — the concurrent scan not only failed to speed things up, it caused the same images to be pulled and partially scanned repeatedly, making it the core amplifier of this IO spike.

### 3.2 Why it was "a daily fixed-time storm" rather than random

Checking `creationTimestamp` via `kubectl get vulnerabilityreports -A`, almost all reports (30+ workloads) were created within the **previous day** (08-16) 14:01–18:10 window — i.e. the initial full-cluster scan done right when trivy-operator was installed. Combined with `OPERATOR_SCANNER_REPORT_TTL: 24h`, this batch of reports expired the next day in the same relative window, triggering the rescan storm. And the initial scan itself, due to the concurrent lock contention above, took nearly 4 hours to finish queueing through (14:01→18:10); this "stretched" time distribution was carried over verbatim to the next day's expiry times, so the rescan storm also dragged on for 4 hours — **the TTL mechanism itself is sound (it's meant to catch drift such as "image unchanged but a new CVE was disclosed"), the real problem was that the concurrent lock bug turned the "once-a-day routine rescan" into a storm spanning 4 hours with continuous failed retries**, and as long as the bug remained unfixed, this pattern would replay every day around the same time.

### 3.3 After fixing the concurrency limit, the cilium job kept failing — the second root cause

After moving `scanJobsConcurrentLimit` to the correct position and setting it to 1 (commit `f666e29`) and verifying it was live, `scan-vulnerabilityreport-c84ff9879` (mapping to the `kube-system/cilium` DaemonSet) still hit `BackoffLimitExceeded` every 45–80 seconds with the same cache lock timeout error. Checking this job's pod spec: the cilium DaemonSet has 6 initContainers (`config`/`mount-cgroup`/`apply-sysctl-overwrites`/`mount-bpf-fs`/`clean-cilium-state`/`install-cni-binaries`) + 1 main container, and trivy-operator, when building the scan job, stuffed all 7 of them into the **same job pod** using regular `containers:` (not K8s `initContainers:`, which would execute sequentially) — Kubernetes starts regular containers in a pod simultaneously by default, so these 7 trivy scan processes still race for the same cache lock simultaneously, **which has nothing to do with `scanJobsConcurrentLimit` (which governs cross-job concurrency), it cannot control concurrency within a single job**.

Comparing `kubectl get daemonset cilium -o json`, confirmed that these 6 initContainers use the **exact same image digest** as the main container (`quay.io/cilium/cilium:v1.20.0@sha256:383968cd...`) — scanning them separately is pure waste. Along the way, comparing initContainer images against main container images across all pods in the cluster, only two cases had genuinely different images: `kyverno-admission-controller`'s `kyverno-pre` (`kyvernopre:v1.18.2`) and `homepage`'s `seed-config` (`busybox:1.36`).

### 3.4 Independent senior SRE review

After fixing the two points above, a separate agent was pulled in (isolated worktree, querying the live cluster directly, not seeing the prior reasoning) to re-examine the whole thing. Results:
- The root-cause judgment held, and even found stronger evidence — the cilium job failed 7 times **before** the concurrency fix and 4 more times **after** it, with identical intervals, directly proving the concurrency limit had no effect on it, the problem was purely intra-pod lock contention
- Both fixed nesting bugs were re-verified in the live ConfigMap, confirmed effective
- **A bigger blind spot newly discovered**: not just homepage, but `hubble-relay` (later proved to be a misjudgment — it was actually vikunja-notify-relay whose container happens to also be named `relay`), `trilium`, `evidence-os-website`, `placeholder-hello` all failed scanning due to the same arm64 problem; additionally the 5 `ops-lab/*:dev` images in `lab-environment` (built locally, never pushed to a registry) failed due to 401 authentication, a completely unrelated cause. Altogether **10+ workloads in the cluster have no VulnerabilityReport at all**
- Checked the logic of `kyverno/policies/require-vuln-scan-clean.yaml`: currently `validationFailureAction: Audit`, it queries all reports under the owner by the `trivy-operator.resource.name` label, denying only if the count of "CRITICAL and has fix version" vulnerabilities is > 0. **When a workload has no report at all, the query returns an empty list and `length > 0` is always false, so it silently passes** — this is not a minor "two initContainers reducing coverage" issue, it means "a scan failure for any reason permanently bypasses this policy for the corresponding workload", with no deny event for post-hoc auditing; if it were switched to Enforce this would be a silent hole
- Objected to the earlier rejection of `builtInTrivyServer` (the resident trivy-server, ClientServer mode): measured memory requests at only 41% (9.9Gi/24Gi) in practice, the previously cited "111% limits overcommit" is a soft ceiling that doesn't affect scheduling; and under Standalone mode the cilium job burst 7 containers at once, each with a 768Mi limit, spiking exposure to 5.4Gi instantly — worse than a stable resident trivy-server eating a 1Gi limit. Recommended putting it on the near-term roadmap rather than rejecting it, since it's the only option that can simultaneously root-cause both "cross-job" and "intra-job" lock contention.

### 3.5 Third finding: `skipInitContainers` itself is an incomplete implementation that never took effect

After adding `skipInitContainers: true` (commit `a54720b`) and restarting trivy-operator, there was a brief misjudgment that "after about 10 minutes the old jobs were gradually cleared and the problem was solved" (see section 5.3's original record and the correction below). Re-checking later with a longer time window, `scan-vulnerabilityreport-c84ff9879` (cilium) was still rebuilding with the 6-initContainer combination, failing, and hitting `BackoffLimitExceeded` **more than 25 minutes after** the setting took effect, at the same 45–80 second interval as before the fix.

First ran a low-risk hypothesis check: could the cilium main container's report built 3 hours earlier have a `resource-spec-hash` label that no longer matches the hash computed now, causing the operator to keep misjudging "report doesn't exist, must rescan"? Deleting that report and letting the operator rebuild it (built successfully at 10:56:00), `c84ff9879` still rebuilt and failed with the 6-container combination **after** the new report was created — directly falsifying the hash-mismatch guess, proving it's a different cause.

Following this thread, re-cloned the trivy-operator source and traced down, finding the problem in `ScanJobBuilder.Get()` in `pkg/vulnerabilityreport/builder.go`:
- Line 181 `kube.GetContainerImagesFromPodSpec(spec, s.skipInitContainers)` does correctly apply the filter, but this line's result is **only used to produce a JSON annotation** (recorded on the Job object's metadata), and does not affect which containers the Job pod actually builds
- What actually decides "which containers go into the Job pod" is line 152 `s.plugin.GetScanJobSpec(...)` (the trivy plugin's own code, in `pkg/plugins/trivy/`) — this call **does not pass `s.skipInitContainers` at all**; it independently recomputes the container list from the original object, unaware of excluding initContainers

In other words: `skipInitContainers: true` only affects the operator's step of deciding "is the existing report sufficient, should a rescan be triggered", and does not actually reduce the initContainers in the scan Job that gets built. A case like cilium particularly gets stuck in a dead loop, presumably because the shortened list still occasionally fails one of `hasVulnReports`/`hasExposedSecretReports` (e.g. the secret report is misaligned); once a rescan is triggered, `GetScanJobSpec` stuffs all 7 containers back in, the rescan fails on lock contention, and can never stabilize the decision condition, hence the infinite loop. **This is an implementation gap in trivy-operator 0.33.0 itself, not something fixable via values.yaml**, and it also causes a new symptom: because `scanJobsConcurrentLimit: 1`, the cilium job that never succeeds yet keeps rebuilding presumably holds the single concurrency slot long-term, so `dify`'s `api`/`worker`/`worker-beat` (three sharing the same image) and `hubble-ui`'s `backend` container never got a scan opportunity at all — not a single attempt in the logs within 40 minutes.

**The real fix**: switch to the already-verified `skipResourceByLabels` mechanism, excluding the entire cilium DaemonSet from scanning entirely (rather than just excluding its initContainers). Found that cilium is not an ArgoCD-managed resource — the Cilium section of `k3s/README.md` states it was a one-time bootstrap installed manually via `helm install`, with no corresponding ArgoCD Application and no selfHeal — so besides adding the label in `vps_oracle/k3s/cilium/values.yaml`, it also requires an extra manual `helm upgrade` against the live cluster (commit `249e9ac`) to take effect, unlike the other fixes that sync automatically via ArgoCD. This operation triggers a pod rebuild of the cilium-agent DaemonSet; on a single-node cluster this means a brief dependency window for the whole cluster's pod network at the moment of rebuild — commands like `helm upgrade` that touch the live CNI directly are proactively blocked by the system's auto-mode classifier to require human confirmation, and were executed only after confirmation.

**The first attempt using `podLabels` still failed, and in the opposite direction from section 3.3**. `podLabels` only renders into `spec.template.metadata.labels` (the pod itself), but trivy-operator's `SkipProcessing` (`pkg/operator/workload/helper.go`) checks `resource.GetLabels()` — i.e. the **top-level labels of the scanned workload object itself**. A DaemonSet has no intermediate layer like a ReplicaSet, so `resource` is directly the DaemonSet itself; what matters is the DaemonSet's own `metadata.labels`, not the pod template. A few minutes after the `helm upgrade` was applied, the cilium job kept hitting `BackoffLimitExceeded`, directly confirming the label had no effect. Checked whether the chart has a key that precisely adds only to the DaemonSet's own metadata: `commonLabels` can reach the DaemonSet's own `metadata.labels`, but its render scope is the **whole chart** (including `hubble-relay`, `hubble-ui`, `cilium-operator`, `cilium-envoy`), excluding far more than intended. Finally switched to labeling the live resource directly (not via chart values):
```bash
kubectl -n kube-system label daemonset cilium trivy-operator.skip=true --overwrite
```
Only changes metadata, doesn't touch pod template/spec, doesn't trigger a rollout (commit `43f97be` records this decision and command in the `values.yaml` comment, while removing the useless `podLabels`). The cost is unchanged: the cilium-agent **main container** is also no longer scanned (not just initContainers), but this is the only way to actually stop the dead loop.

### 3.6 Root solution for the arm64 scan failure

When the Trivy CLI scans a multi-arch / single-arch image, it defaults to assuming `linux/amd64`, and without `--platform` it immediately errors with "By default, only Linux amd64 images are supported for scanning" — this node is Oracle Ampere (arm64), and homepage/trilium/evidence-os-website/placeholder-hello/vikunja-notify-relay are all **single-arch** images built with `platforms: linux/arm64` by this repo's own CI (`.github/workflows/patched-images.yml` etc.), with no amd64 variant to fall back to, so they all inevitably fail.

A separate agent was pulled in specifically to look for a chart-level root solution: checked the chart templates (`templates/configmaps/trivy.yaml`) — no direct `trivy.platform` key, but there is a pass-through `trivy.configFile`; checked the trivy-operator Go source (`pkg/plugins/trivy/image.go`) confirming this ConfigMap key really gets mounted as `/etc/trivy/trivy-config.yaml` and passed to the trivy binary's `--config`; checked the trivy CLI source (`pkg/flag/image_flags.go`) confirming the config file format supports `image.platform`. **Actual end-to-end test**: opened a standalone test pod in `trivy-system` (using the same trivy image+tag actually in use in the cluster), mounted a test config of `image:\n  platform: linux/arm64`, and ran `trivy image --config ...` directly against the actually-failing homepage image — successfully resolved Alpine 3.24.1, completed the vulnerability scan, and produced normal JSON; then cleaned up the test pod and ConfigMap, leaving no trace in the repo or cluster. Confirmed the cluster-wide application is safe: the node is 100% arm64, so any image that can actually run is necessarily arm64-compatible.

## 4. Root-cause chain

```
values.yaml's scanJobsConcurrentLimit placed at the wrong YAML layer (top level, not under operator:)
  → Helm silently ignores it, applying the chart default of 10 (not the intended 3)
    → 10 scan jobs share a single local file-lock cache that doesn't support concurrency
      → Many "cache may be in use by another process: timeout", retries, some BackoffLimitExceeded
        → Every failure had first fully pulled the image layer, pure wasted disk IO
          → The initial full-cluster scan dragged out to nearly 4 hours
            → The 24h TTL expiry inherited the same 4-hour stretched distribution
              → The "rescan storm" replays daily around the same time
                → On top of cilium DaemonSet's 6 initContainers (same image as main container)
                  → Treated as 7 independent containers stuffed into the same job pod, started simultaneously by Kubernetes default
                    → Even with cross-job concurrency limited to 1, intra-job self lock contention causes continuous failure
                      → On top of multiple workloads failing all scans due to single-arch arm64 images and retrying continuously
                        → Many small IOs (retries + partially completed image pulls) push up IO PSI full
                          → 15% threshold sustained for 2 minutes → io_pressure_critical fires repeatedly
```

In one sentence: **two independent Helm values misplaced layers (bugs that never took effect), compounded by trivy-operator mishandling both "multiple containers in the same job" and "single-arch images", together turned the "once-a-day routine security scan" into a daily fixed-time, hours-long IO storm full of failed retries.**

## 5. Remediation process

### 5.1 Fix list (in commit order)

| commit | Content | Verification method |
|---|---|---|
| `f666e29` | Moved `scanJobsConcurrentLimit` under `operator:`, set to 1 | Live ConfigMap confirms `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT=1` |
| `2817e63` | Added `trivy-operator.skip` label to homepage (the approach at the time, later found ineffective) | See "two self-inflicted layer mistakes" below |
| `86e53ea` | Fixed `skipResourceByLabels` also placed at the wrong layer (mistakenly under `operator:`, should be `trivyOperator:`) | **Run `helm template` first to confirm the rendered result, then commit** — this is the process change adopted after the first pitfall |
| `a54720b` | `trivyOperator.skipInitContainers: true` + `trivy.configFile: {image: {platform: linux/arm64}}` | `helm template` render verification + post-push live ConfigMap double check |
| `ab2e15f` | Removed the now-useless `trivy-operator.skip` label on homepage | That label was placed on the Deployment's own `metadata.labels` and never propagated to the actually-scanned ReplicaSet (only `spec.template.metadata.labels` propagates), so it never took effect; with the arm64 root fix, skipping is no longer needed |

**Two layer mistakes I made and then corrected myself**, recorded to avoid repeating:
1. `scanJobsConcurrentLimit` should go under `operator:`, initially placed at the top level
2. `skipResourceByLabels` should go under `trivyOperator:` (the chart splits operator controller settings and scan-job/report behavior into two different top-level keys); initially, following the lesson learned the first time, it was placed under `operator:` — but that was the wrong block again

From the second time onward the process changed: **any values.yaml change first runs `helm template <chart> --repo <url> --version <ver> -f values.yaml | grep <target-key>` to confirm the rendered result is non-empty and correct before commit/push** — the chart silently ignores unrecognized keys entirely, so eyeballing values.yaml or looking at the git diff can't reveal a wrong layer.

### 5.2 ArgoCD sync and live verification

With `automated selfHeal` on, after push it's routine to `annotate argocd.argoproj.io/refresh=hard` to trigger sync immediately instead of waiting for the default polling. A detail that's easy to miss: of trivy-operator's three ConfigMaps (`trivy-operator-config`, `trivy-operator`, `trivy-operator-trivy-config`), only content changes to `trivy-operator-config` trigger a rollout automatically via the pod template's `checksum/config` annotation; when the other two ConfigMaps change, even though the live content is updated, **the controller pod does not auto-restart** (these settings are read once at startup, not watched live), so you must manually `kubectl rollout restart deployment/trivy-operator` to actually apply — the first `skipResourceByLabels` change missed this step, and it was only caught by checking with `kubectl exec ... env` that the new pod lacked the corresponding value.

### 5.3 Verifying whether the fix really took effect, with a misjudgment in the middle (later proven that this misjudgment itself was also wrong, see 3.5)

Right after restart, `scan-vulnerabilityreport-c84ff9879` (cilium) hit `BackoffLimitExceeded` once more, and it was briefly thought `skipInitContainers` didn't take effect. The investigation at the time: cloned the `aquasecurity/trivy-operator` v0.33.0 source confirming `GetContainerImagesFromPodSpec` in `pkg/kube/resources.go` has the correct logic (`if !skipInitContainers { add InitContainers }`), and simultaneously confirmed a freshly built job after restart (dify `worker-beat`, no initContainer interference) had a normal container count; **concluded it was "pre-restart old Job objects winding down", not a failed fix**, and after about 10 minutes no more new multi-container jobs were seen, so the problem was considered solved at the time.

**That conclusion was wrong** — only checked whether `GetContainerImagesFromPodSpec`'s own logic is correct, without tracing all the way to "is the result of this function actually used to build the Job". Re-checking 25 minutes later with a longer observation window, the cilium job had in fact never truly stopped; it's just that the retry interval (45–80 seconds) happened to make the ~10-minute observation window at the time look like "winding down completed". The real root cause and fix are in section 3.5.

## 6. Results

| Metric | At incident time | After remediation |
|---|---|---|
| IO PSI full (historical peak) | Highest 77.9% (13:40), multiple 25–35% waves | avg10 back to 0–0.5% normal; a full rescan triggered once produced a small blip around avg10 2%, far below the 15% threshold |
| trivy scan job cache lock failures (within 6h) | 36 times, concentrated in the single cilium job (77%) | Cross-job lock contention gone to zero after the `scanJobsConcurrentLimit` fix; cilium self lock contention only truly stopped after labeling the DaemonSet's own `metadata.labels` directly (not the chart's `podLabels`) — **confirmed stable for over 13 minutes with no recurrence** (see 3.5) |
| cilium DaemonSet scan | `BackoffLimitExceeded` every 45–80s, never a successful report | Entire DaemonSet (including main container) now excluded from scanning, no more retries; the cost of lost main-container vulnerability coverage is consciously accepted (see 3.5) |
| homepage/trilium/evidence-os-website/placeholder-hello/vikunja-notify-relay | 100% scan failure (amd64-only error) | All 5 verified scanning successfully (live end-to-end confirmation, cross-checked one by one via `kubectl get vulnerabilityreport -A`); of which homepage's `seed-config` initContainer was later retried and re-failed due to the same `skipInitContainers` gap from section 3.5 — small scale (only 2 containers racing, not 7), won't cause an IO storm, and the result matches the originally accepted cost (seed-config has no report), so not a new problem |
| dify `api`/`worker`/`worker-beat`, hubble-ui `backend` | (not specifically checked at incident time) | Even after cilium stopped retrying, and even after restarting trivy-operator to force a full rescan, these still got no scan attempt at all — **the original hypothesis "cilium holding the concurrency slot" does not hold** (they still weren't scheduled after cilium stopped), the real cause is unknown and listed in section 7 for follow-up |
| `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT` | 10 (the chart default, not the never-effective intended `3`) | 1, live-confirmed |

## 7. Open items / follow-up (not yet decided, left to the user)

1. **Kyverno `require-vuln-scan-clean` fail-open gap**: currently still in `Audit` mode with no actual impact, but the underlying logic is "no report found → pass" rather than "0 vulnerabilities found → pass". Before truly switching to `Enforce`, a `kubectl get vulnerabilityreports -A` vs `kubectl get pods -A` cross-check must be done to build a punch list of "zero report" workloads — currently known to be on the list: `lab-environment`'s 5 `ops-lab/*:dev` images (401 authentication, completely unrelated to this fix), `dify`'s `api`/`worker`/`worker-beat`, `hubble-ui`'s `backend` (cause in 3.5, to be confirmed whether it resolves after the cilium fix), and **the now deliberately excluded cilium-agent main container** (a direct cost of the 3.5 fix, a conscious tradeoff, not a gap, but still invisible to this policy).
2. **`operator.builtInTrivyServer` (ClientServer mode) not adopted**: the independent review in section 3.4 explicitly opposed "outright rejecting" this option. Section 3.5 then found `skipInitContainers` itself is an incomplete implementation that actually never solved the cilium problem, forcing the cruder "exclude entirely" workaround — **further corroborating the review's judgment at the time that the current fix is still fundamentally fragile**, and that ClientServer mode is the only option that lets the cilium main container be scanned again while no longer worrying about the concurrency setting being changed back by anyone. Its priority should be raised, not just "near-term evaluation".
3. **Whether some workloads should move back to docker-compose**: another independent assessment considered `homepage`/`trilium`/`evidence-os-website`/`placeholder-hello` (architecture reasons, not because of this arm64 issue) and `dify` (the strongest case — officially maintained via compose upstream, and what runs now is a hand-translated k8s version) worth considering for migration; the `lab-environment` namespace should stay on k3s (confirmed as a deliberately kept demo environment for practicing k8s-native patterns). **With this arm64 root fix in place, the earlier "incidental urgency" for homepage/trilium has evaporated**, and migration is purely a long-term architectural-simplification decision, not something to rush because of this incident.
4. **The `--slow` flag used by trivy is already marked deprecated** (chart/CLI logs suggest switching to `--parallel 1`), currently functionally equivalent, but the semantics may change on future chart upgrades, worth re-confirming concurrency behavior at that time.
5. **Keeping the `trivyOperator.skipInitContainers` setting itself does no harm, but don't rely on it**: although useless for cilium, for the general case where "initContainer differs from main container and there's no self lock contention", it should still work in theory (though "working" only extends to the operator's own rescan-decision logic, and does not affect the content of Jobs already running). To truly keep a workload from being scanned, still use `skipResourceByLabels`, don't expect `skipInitContainers` alone to solve intra-pod multi-container lock contention cases.
6. **Cilium's fix (manual `helm upgrade`) differs from the other fixes** because cilium has never been an ArgoCD-managed resource since install (see `k3s/README.md`). If `vps_oracle/k3s/cilium/values.yaml` changes again, remember it also needs a manual `helm upgrade` to take effect; a git commit alone does not trigger any auto-sync — easy to confuse with the GitOps convention for other k3s resources in this repo. Additionally, the `trivy-operator.skip` label itself is **not expressed through chart values** (the chart has no key that precisely lands only on a single resource's own metadata), and was applied directly via `kubectl label daemonset`; `values.yaml` only keeps a comment recording the command — if the cilium DaemonSet is ever deleted and rebuilt entirely for some reason (rather than just `helm upgrade`), this label will not auto-restore, so it must be re-applied.
7. **Why dify `api`/`worker`/`worker-beat` and hubble-ui `backend` never got scheduled for scanning is still unknown**: initially suspected the cilium dead loop holding the single `scanJobsConcurrentLimit: 1` concurrency slot, but after cilium stopped retrying, and even after restarting trivy-operator to force a full re-reconcile, these still never had a single attempt — overturning the "slot held" explanation. Doesn't affect the IO PSI conclusion (they're just zero-scan, producing no IO load), but remember it feeds into the Kyverno audit list in item 1. Later, `kubectl -n trivy-system logs deployment/trivy-operator` combined with a manual trigger (e.g. changing a harmless annotation on these Deployments to force a reconcile) can be used to investigate.

## 8. Appendix: reusable commands

```bash
# Query Prometheus from inside the container (the container exposes no port)
docker exec prometheus wget -qO- "http://localhost:9090/api/v1/query_range?query=rate(node_pressure_io_stalled_seconds_total%5B2m%5D)*100&start=<unix>&end=<unix>&step=60"

# Check the actual failure message of each container in a trivy scan job (the pod is usually already deleted, so check the operator's own logs)
kubectl -n trivy-system logs deployment/trivy-operator --since=6h | grep '"job":"trivy-system/scan-vulnerabilityreport-<hash>"'

# For any Helm values change, verify the rendered result before commit — don't rely on eyeballing YAML indentation
helm template <release> --repo <repo-url> --version <ver> -f values.yaml | grep -A3 <target-key>

# Trigger ArgoCD sync immediately (without waiting for the default polling cycle), annotate multiple apps together
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite

# When a ConfigMap changed but the controller pod has no checksum annotation covering it, restart manually to re-read
kubectl -n <ns> rollout restart deployment/<controller>
kubectl -n <ns> rollout status deployment/<controller> --timeout=60s

# Determine whether a perpetually failing scan job is "an old object winding down" rather than a failed fix
kubectl -n trivy-system get job <job-name> -o jsonpath='{.metadata.creationTimestamp}'  # compare against the fix-effective time point

# Compare initContainer images vs main container images across the cluster (assess the cost of skipInitContainers)
kubectl get pods -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    spec = item['spec']
    main_images = set(c['image'] for c in spec.get('containers', []))
    for ic in spec.get('initContainers', []):
        status = 'SAME' if ic['image'] in main_images else 'DIFFERENT'
        print(status, item['metadata']['namespace']+'/'+item['metadata']['name'], ic['name'], ic['image'])
"

# End-to-end verification that the trivy config really takes effect (without touching the live environment, standalone test pod)
kubectl -n trivy-system run trivy-test --rm -it --image=mirror.gcr.io/aquasec/trivy:0.73.0 \
  --overrides='{"spec":{"containers":[{"name":"trivy-test","image":"mirror.gcr.io/aquasec/trivy:0.73.0","command":["sleep","3600"],"volumeMounts":[{"name":"cfg","mountPath":"/etc/trivy"}]}],"volumes":[{"name":"cfg","configMap":{"name":"<test-configmap>"}}]}}' \
  -- trivy image --config /etc/trivy/trivy-config.yaml <target-image-ref>

# Determine whether a perpetually failing job means the fix really didn't take effect — don't conclude after just 10 minutes —
# use a fixed --since-time (not relative time) overlapping query to confirm a phenomenon "only appears after the fix-effective time point"
kubectl -n trivy-system logs deployment/trivy-operator --since-time=<fix-effective-UTC-timestamp> | \
  grep -oE '"job":"trivy-system/scan-vulnerabilityreport-<hash>","container":"[a-z-]+"' | sort -u

# Find which containers a perpetually failing job is currently scanning (live, not from historical logs)
JOB=<job-hash>
kubectl -n trivy-system get pod -l job-name=scan-vulnerabilityreport-$JOB \
  -o jsonpath='{.items[0].spec.containers[*].name}'

# Determine whether a workload is ArgoCD-managed or manually bootstrapped (the fix approach differs completely)
kubectl -n argocd get application -A | grep <keyword; no result means manually installed>
# If confirmed manually installed (e.g. cilium in this incident), the change takes effect via:
helm upgrade <release> <chart> --repo <repo-url> --version <ver> \
  --namespace <ns> -f <values.yaml> --kubeconfig /etc/rancher/k3s/k3s.yaml
```
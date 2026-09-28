# Lab Resilience Scenarios (Sub-project 2c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four new live-demoable resilience scenarios on `lab-environment` — one bad pod ejected (14), header-triggered fault injection (15), Toxiproxy network faults on a dependency (17), rate limiting (16) — plus 08 rewritten as capacity-and-overload-protection, and every open thread the roadmap assigns to 2c closed (ledger C and D, the two "Ready but not routable" findings, the waypoint-roll connection drops, 2a minors group B).

**Architecture:** A new fork toggle (`chaos/<svc>/fail-instance` = a pod name → that pod answers 503) gives outlier detection a real bad upstream. A resident `TrafficExtension` + Lua token bucket and a tight `connectionPool` protect the measured bottleneck (vets-service). Fault injection and Toxiproxy are demo-only `demo:` patches, reverted on the page; `demo-reset` checks that none is left behind. Open findings are reproduced, measured, and end fixed or accepted in writing.

**Tech Stack:** Istio 1.30 ambient (waypoint VirtualService / DestinationRule / TrafficExtension), ArgoCD, Kubernetes, Toxiproxy 2.9, bash helpers + stubbed tests, Loki / Prometheus / Grafana, Spring Boot 4 (petclinic fork, Maven), k6.

**Spec:** [docs/superpowers/specs/2026-09-28-lab-resilience-scenarios-design.md](../specs/2026-09-28-lab-resilience-scenarios-design.md)

## Global Constraints

- **Ask the owner before every `git push` that touches `k3s/`** (standing rule). Batch one task's pushes into one question where possible. Lab roadmap work commits straight to `main`.
- **Other Claude sessions may commit to `main` in this checkout**: `git status` and `git log -3` before every commit; `git pull --ff-only` before every push.
- **Confirm with the owner before**: pushing the fork to GitHub; `kubectl rollout restart` of the waypoint (Task 12); disabling selfHeal on `kube-state-metrics` (Task 10).
- Committed text (messages, comments, docs) in English; one logical change per commit; every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Fork: `~/jerome/spring-petclinic-microservices`, branch `main`. Images built with `~/jerome/lab-environment/scripts/build.sh` (refuses a dirty tree, prints `FORK_TAG=`), imported with `push-to-k3s.sh` (refuses `:dev`). Manifests reference 12-char SHA tags only.
- Chaos toggle key: `chaos/<service>/fail-instance`; value = the pod name to fail, `false` for none. The reset writes `false` — the existing baseline check already flags any `chaos/` value other than `false`.
- Scenario names (files under `demo/scenarios/`, pages in `docs/demo/`): `bad-pod` (14), `fault-injection` (15), `toxiproxy` (17), `rate-limit` (16), `load-test` (08, rewritten).
- Demo order: … 12 → **14 → 15 → 17** → 04 → 05 → 06 → **16** → **08**.
- Page structure: purpose → preconditions → commands → expected result → evidence → talking points → reset. Pages that push use 2b's sync wait with a deadline (as in `docs/demo/11-header-canary.md`).
- `demo-evidence` passes only with ≥ 2 pieces and ≥ 1 infrastructure layer — unchanged.
- Execution ledger (gitignored, this machine only): `.superpowers/sdd/2026-09-28-lab-resilience-scenarios/progress.md`. Every probe result, measured value and ruling goes there as it happens.
- Helper tests: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh` must end `ALL PASS` after every helper change. Helpers do not deploy (ArgoCD syncs only `k8s/`).
- **Spec correction** (found while planning): visits-service already sets `spring.data.redis.timeout: 2s` and `connect-timeout: 1s` (fork `application.yml`), so 17's talking point is "the app's Redis timeout (2 s) is longer than the mesh's 1 s per-try timeout; Hikari waits 30 s" — not Lettuce's 60 s default. Also: the existing `baseline_check` chaos test already catches a leftover `fail-instance`, so no new code is needed for that spec bullet — Task 3 only pins it with a test.

## Review Focus

1. **The fail-instance filter also answers actuator paths with 503** → the pod fails readiness and leaves the endpoint list (nothing left to eject) or liveness restarts it. Expected: `/actuator/**` is never failed. Pinned by Task 1's `actuatorIsNeverFailed` test.
2. **`HOSTNAME` unset and the toggle never set** → `"".equals("")` fails every pod at once. Expected: an empty name never matches. Pinned by Task 1's `emptyNamesNeverMatch` test.
3. **A forgotten 17 revert** (visits still routed through toxiproxy, postgres still admitting `sa/toxiproxy`) → later scenarios run on a silently degraded path. Expected: `demo-reset` fails and names it. Pinned by Task 6's baseline tests.
4. **The resident limiter clips steady traffic** (generator, the `Lab API Down` probe) → a false production alert every day. Expected: zero 429 over a 10-minute steady-state window after it lands. Pinned by Task 7 Step 6's gate.
5. **08's minute table across UTC midnight** → rows silently dropped by a `HH:MM` join. Expected: every minute appears once, in order. Pinned by Task 9's midnight test.

---

### Task 1: Fork — `fail-instance` toggle in customers-service and visits-service

**Files (fork `~/jerome/spring-petclinic-microservices`):**
- Modify: `spring-petclinic-customers-service/src/main/java/org/springframework/samples/petclinic/customers/chaos/ChaosToggles.java`
- Modify: `spring-petclinic-customers-service/src/main/java/org/springframework/samples/petclinic/customers/chaos/ChaosToggleWatcher.java:40`
- Create: `spring-petclinic-customers-service/src/main/java/org/springframework/samples/petclinic/customers/chaos/FailInstanceFilter.java`
- Test: `spring-petclinic-customers-service/src/test/java/org/springframework/samples/petclinic/customers/chaos/FailInstanceFilterTest.java`, `.../ChaosTogglesTest.java`
- The same four in `spring-petclinic-visits-service/…/visits/chaos/` (package `org.springframework.samples.petclinic.visits.chaos`)

**Interfaces:**
- Produces: `ChaosToggles.value(String) : String` (never null), `ChaosToggles.set(String, String)`; Consul key `chaos/<svc>/fail-instance`; the failed pod answers `503` with body `chaos: fail-instance`; Spring metric `http_server_requests_seconds_count{status="503"}` on that pod.

- [ ] **Step 1: Create the ledger**

```bash
cd ~/jerome/docker-gitops
mkdir -p .superpowers/sdd/2026-09-28-lab-resilience-scenarios
printf '# 2c execution ledger\n\nPlan: docs/superpowers/plans/2026-09-28-lab-resilience-scenarios.md\n' > .superpowers/sdd/2026-09-28-lab-resilience-scenarios/progress.md
```

- [ ] **Step 2: Confirm both services are servlet (MVC) apps and their chaos classes are identical**

```bash
cd ~/jerome/spring-petclinic-microservices
grep -n 'spring-boot-starter-web' spring-petclinic-{customers,visits}-service/pom.xml
diff <(sed 's/visits/X/g' spring-petclinic-visits-service/src/main/java/org/springframework/samples/petclinic/visits/chaos/ChaosToggles.java) \
     <(sed 's/customers/X/g' spring-petclinic-customers-service/src/main/java/org/springframework/samples/petclinic/customers/chaos/ChaosToggles.java) && echo identical
```
Expected: a servlet web starter in both (not `webflux`); `identical`. If either is WebFlux, stop and record it — the filter below is servlet-only.

- [ ] **Step 3: Write the failing tests (customers)**

`FailInstanceFilterTest.java`:

```java
package org.springframework.samples.petclinic.customers.chaos;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import static org.assertj.core.api.Assertions.assertThat;

class FailInstanceFilterTest {

    private final ChaosToggles toggles = new ChaosToggles();

    private MockHttpServletResponse call(String instanceName, String uri, MockFilterChain chain) throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        new FailInstanceFilter(toggles, instanceName).doFilter(new MockHttpServletRequest("GET", uri), response, chain);
        return response;
    }

    @Test
    void failsThisInstanceWhenTheToggleNamesIt() throws Exception {
        toggles.set("fail-instance", "customers-service-abc");
        MockFilterChain chain = new MockFilterChain();

        MockHttpServletResponse response = call("customers-service-abc", "/owners/1", chain);

        assertThat(response.getStatus()).isEqualTo(503);
        assertThat(response.getContentAsString()).isEqualTo("chaos: fail-instance");
        assertThat(chain.getRequest()).isNull();
    }

    @Test
    void servesNormallyWhenTheToggleNamesAnotherInstance() throws Exception {
        toggles.set("fail-instance", "customers-service-xyz");
        MockFilterChain chain = new MockFilterChain();

        MockHttpServletResponse response = call("customers-service-abc", "/owners/1", chain);

        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(chain.getRequest()).isNotNull();
    }

    @Test
    void servesNormallyWhenTheToggleIsFalse() throws Exception {
        toggles.set("fail-instance", "false");
        MockFilterChain chain = new MockFilterChain();

        assertThat(call("customers-service-abc", "/owners/1", chain).getStatus()).isEqualTo(200);
        assertThat(chain.getRequest()).isNotNull();
    }

    @Test
    void emptyNamesNeverMatch() throws Exception {
        MockFilterChain chain = new MockFilterChain();   // toggle never set: value is ""

        assertThat(call("", "/owners/1", chain).getStatus()).isEqualTo(200);
        assertThat(chain.getRequest()).isNotNull();
    }

    @Test
    void actuatorIsNeverFailed() throws Exception {
        toggles.set("fail-instance", "customers-service-abc");
        MockFilterChain chain = new MockFilterChain();

        assertThat(call("customers-service-abc", "/actuator/health/readiness", chain).getStatus()).isEqualTo(200);
        assertThat(chain.getRequest()).isNotNull();
    }
}
```

Append to `ChaosTogglesTest.java`:

```java
    @Test
    void valueKeepsTheRawStringAndDefaultsToEmpty() {
        ChaosToggles chaosToggles = new ChaosToggles();

        assertThat(chaosToggles.value("fail-instance")).isEmpty();
        chaosToggles.set("fail-instance", "customers-service-abc");
        assertThat(chaosToggles.value("fail-instance")).isEqualTo("customers-service-abc");
        assertThat(chaosToggles.isEnabled("fail-instance")).isFalse();
        chaosToggles.set("fail-instance", (String) null);
        assertThat(chaosToggles.value("fail-instance")).isEmpty();
    }
```

- [ ] **Step 4: Run to verify they fail**

Run: `./mvnw -q -pl spring-petclinic-customers-service test -Dtest='FailInstanceFilterTest,ChaosTogglesTest'`
Expected: compilation failure — `FailInstanceFilter` and `value(String)` do not exist.

- [ ] **Step 5: Implement (customers)**

`ChaosToggles.java` — replace the class body:

```java
@Component
public class ChaosToggles {

    // Raw values from Consul: booleans for the on/off toggles, a pod name for
    // fail-instance.
    private final Map<String, String> values = new ConcurrentHashMap<>();

    public boolean isEnabled(String name) {
        return Boolean.parseBoolean(values.get(name));
    }

    public String value(String name) {
        return values.getOrDefault(name, "");
    }

    public void set(String name, boolean enabled) {
        set(name, Boolean.toString(enabled));
    }

    public void set(String name, String value) {
        values.put(name, value == null ? "" : value);
    }
}
```

`ChaosToggleWatcher.java:40` — store the raw value:

```java
                chaosToggles.set(name, value.getDecodedValue());
```

`FailInstanceFilter.java`:

```java
package org.springframework.samples.petclinic.customers.chaos;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Makes exactly one instance misbehave: while chaos/customers-service/fail-instance
 * holds this pod's name, every business request gets 503. Actuator is exempt so
 * the pod stays Ready and alive - the point is an instance the platform still
 * routes to, which only outlier detection can take out.
 */
@Component
public class FailInstanceFilter extends OncePerRequestFilter {

    static final String TOGGLE = "fail-instance";

    private final ChaosToggles chaosToggles;
    private final String instanceName;

    public FailInstanceFilter(ChaosToggles chaosToggles, @Value("${HOSTNAME:}") String instanceName) {
        this.chaosToggles = chaosToggles;
        this.instanceName = instanceName;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return request.getRequestURI().startsWith("/actuator");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        if (!instanceName.isEmpty() && instanceName.equals(chaosToggles.value(TOGGLE))) {
            response.setStatus(HttpServletResponse.SC_SERVICE_UNAVAILABLE);
            response.getWriter().write("chaos: fail-instance");
            return;
        }
        chain.doFilter(request, response);
    }
}
```

- [ ] **Step 6: Run the module's whole suite**

Run: `./mvnw -q -pl spring-petclinic-customers-service test`
Expected: BUILD SUCCESS, including the existing `ChaosToggleWatcherTest` (it sets `"true"`/`"false"` strings, which `isEnabled` still parses).

- [ ] **Step 7: Repeat Steps 3–6 for visits-service** — the same files with package `org.springframework.samples.petclinic.visits.chaos`, pod names `visits-service-abc` / `visits-service-xyz` in the tests, and the Javadoc naming `chaos/visits-service/fail-instance`. Run: `./mvnw -q -pl spring-petclinic-visits-service test` → BUILD SUCCESS.

- [ ] **Step 8: Commit in the fork**

```bash
git add spring-petclinic-customers-service spring-petclinic-visits-service
git commit -m "Add a per-instance fail toggle to customers and visits

chaos/<svc>/fail-instance names one pod; that pod answers 503 to every
non-actuator request, so outlier detection has a real bad upstream.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Build and import the images**

```bash
cd ~/jerome/lab-environment && ./scripts/build.sh          # note FORK_TAG=<sha12>
./scripts/push-to-k3s.sh ops-lab/customers-service:<sha12> ops-lab/visits-service:<sha12>
```
Record `FORK_TAG` in the ledger.

- [ ] **Step 10: Ask the owner to confirm pushing the fork's `main` to GitHub**, then `git -C ~/jerome/spring-petclinic-microservices push`.

---

### Task 2: Roll the new images into the lab

**Files:**
- Modify: `k3s/apps/lab-environment/k8s/customers-service.yaml` (`image:`), `k3s/apps/lab-environment/k8s/visits-service.yaml:36`

**Interfaces:**
- Consumes: Task 1's `FORK_TAG`.
- Produces: stable customers (×5) and visits (×1) pods that honour `fail-instance`; the Prometheus `cluster_name` value of the customers stable cluster (used by Task 3).

- [ ] **Step 1: Edit both `image:` lines to `ops-lab/<svc>:<FORK_TAG>`** (the canary manifest keeps its v2-good tag).

- [ ] **Step 2: Commit, ask the owner, push, watch**

```bash
git status --short; git log --oneline -3
git commit -m "lab: roll customers and visits to the fail-instance build" -- k3s/apps/lab-environment/k8s/customers-service.yaml k3s/apps/lab-environment/k8s/visits-service.yaml
git pull --ff-only && git push
start=$(date -u +%FT%TZ)
kubectl -n lab-environment rollout status deploy/customers-service --timeout=10m
kubectl -n lab-environment rollout status deploy/visits-service --timeout=6m
kubectl -n lab-environment logs deploy/traffic-generator --since-time="$start" | awk '$2 != "200"' | wc -l
```
Expected: both rollouts complete; `0` non-200 lines. Record the count and the window. A non-zero count is not fixed here — record it for Task 11 (same "Ready but not routable" family).

- [ ] **Step 3: Probe the toggle live**

```bash
BAD=$(kubectl -n lab-environment get pods -l app=customers-service,track=stable -o jsonpath='{.items[0].metadata.name}')
curl -s -X PUT -d "$BAD" http://10.0.0.95:30092/v1/kv/chaos/customers-service/fail-instance; sleep 6
for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners/1; done | sort | uniq -c
W=$(kubectl -n lab-environment get pods -l gateway.networking.k8s.io/gateway-name=waypoint -o jsonpath='{.items[0].metadata.name}')
kubectl -n lab-environment exec "$W" -- pilot-agent request GET stats | grep -E 'customers-service.*outlier_detection.ejections_active'
kubectl -n lab-environment exec "$BAD" -- curl -s -o /dev/null -w '%{http_code}\n' localhost:8081/actuator/health/readiness
curl -s -G http://10.0.0.95:30093/api/v1/query --data-urlencode 'query=envoy_cluster_outlier_detection_ejections_active{cluster_name=~".*customers-service.*"}' | jq -r '.data.result[] | "\(.value[1]) \(.metric.cluster_name)"'
curl -s -X PUT -d false http://10.0.0.95:30092/v1/kv/chaos/customers-service/fail-instance
```
Expected: 60 × `200` (the 503 retried onto another host); `ejections_active 1` on the stable cluster of at least one waypoint replica; readiness `200` on the bad pod; the Prometheus series with its `cluster_name`. If any request was not 200, or nothing was ejected, stop: the mechanism is not what the spec assumed.

---

### Task 3: Scenario 14 — one bad pod is ejected

**Files:**
- Create: `k3s/apps/lab-environment/demo/scenarios/bad-pod.sh`
- Create: `docs/demo/14-bad-pod.md`
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh` (curl stub value; new section)

**Interfaces:**
- Consumes: `CUST_SEL`, `loki_count`, `prom`, `prom_delta`, `settle`, `rec_if` (lib.sh); the `cluster_name` recorded in Task 2 Step 3.
- Produces: `evidence_bad_pod`, `reset_bad_pod`; state file `$STATE_DIR/bad-pod.name` (written by the page).

- [ ] **Step 1: Write the failing tests** — in `test-demo-helpers.sh`, make the curl stub's chaos value overridable (line 22):

```bash
    if [ -n "${FAKE_CHAOS_ON:-}" ]; then v=${FAKE_CHAOS_VALUE:-dHJ1ZQ==}; else v=ZmFsc2U=; fi
```

After the `reset fails on any chaos key` check, add:

```bash
FAKE_CHAOS_ON=chaos/customers-service/fail-instance FAKE_CHAOS_VALUE=$(printf customers-service-abc | base64) \
  check "reset fails while fail-instance names a pod" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "chaos/customers-service/fail-instance"
```

Before the `# --- runbook pages` section, add:

```bash
# 14: the bad pod was ejected; retries hid it from every user.
cp "$DEMO/scenarios/bad-pod.sh" "$DEMO_SCENARIO_DIR/"
win bad-pod 1000 1300
echo customers-service-abc > "$DEMO_STATE_DIR/bad-pod.name"
cat > "$WORK/hook14" <<'EOF'
#!/bin/bash
case "$1" in
  *"ejections_active"*) val "${E14:-1}" ;;
  *"attempts > 1"*) val "${R14:-9}" ;;
  *"response_code != "*) val "${F14:-0}" ;;
  *"customers-service-abc"*"time=1000"*) val 0 ;;
  *"customers-service-abc"*"time=1320"*) val 10 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook14"
FAKE_CURL_HOOK=$WORK/hook14 check "14 passes: ejected, retried, no user error" 0 "$DEMO/demo-evidence" bad-pod
has "$WORK/out" "answered 10 requests with 503 itself"
E14=0 FAKE_CURL_HOOK=$WORK/hook14 check "14 fails when nothing was ejected" 1 "$DEMO/demo-evidence" bad-pod
F14=2 FAKE_CURL_HOOK=$WORK/hook14 check "14 fails when a user saw an error" 1 "$DEMO/demo-evidence" bad-pod
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh | grep -E '^FAIL|14|fail-instance'`
Expected: `reset fails while fail-instance names a pod` already **PASS** (the existing chaos check covers it — this pins it); the three `14` checks FAIL (`unknown scenario 'bad-pod'`).

- [ ] **Step 3: Write `bad-pod.sh`** (swap in the `cluster_name` regex from Task 2 Step 3 if `.*customers-service.*` also matches clusters it should not):

```bash
# 14 — one bad pod: outlier detection ejects it, and the retry policy sends
# its failed attempts to another pod, so no user sees the 503s.
evidence_bad_pod() {
  local ej retried failed bad own
  settle
  ej=$(prom "max_over_time(max(envoy_cluster_outlier_detection_ejections_active{job=\"envoy-stats\", cluster_name=~\".*customers-service.*\"})[${SETTLED_RANGE}s:15s])" "$SETTLED_AT")
  rec_if envoy "customers-service hosts ejected at once, peak: $ej (want >= 1)" \
    awk "BEGIN { exit !(\"$ej\" != \"none\" && $ej + 0 >= 1) }"
  retried=$(loki_count "$CUST_SEL | attempts > 1" "$WINDOW_START" "$WINDOW_END")
  failed=$(loki_count "$CUST_SEL | response_code != \"200\"" "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "requests retried onto another pod: $retried (want > 0); customers requests that still failed: $failed (want 0)" \
    [ "$retried" -gt 0 -a "$failed" -eq 0 ]
  bad=$(cat "$STATE_DIR/bad-pod.name")
  own=$(prom_delta "http_server_requests_seconds_count{pod=\"$bad\", status=\"503\"}")
  rec_if app "the bad pod ($bad) answered $own requests with 503 itself (want >= 5)" [ "$own" -ge 5 ]
}

reset_bad_pod() {
  curl -sf -X PUT -d false "$CONSUL/v1/kv/chaos/customers-service/fail-instance" >/dev/null
  sleep 10   # the fork's ChaosToggleWatcher polls every 5 s
}
```

- [ ] **Step 4: Run the tests** — expected `ALL PASS`.

- [ ] **Step 5: Write `docs/demo/14-bad-pod.md`**

````markdown
# 14 — One bad pod is ejected

## Purpose
Make exactly one of the five customers-service pods fail every request, and
show the mesh take it out of rotation on its own: retries hide the failures
from users, outlier detection stops sending it traffic.

## Preconditions
Preflight passed; the routing scenarios are reset. Runs first among the
resilience scenarios: an ejection lasts 30 s and grows on each repeat.

## Commands
```bash
BAD=$(kubectl -n lab-environment get pods -l app=customers-service,track=stable -o jsonpath='{.items[0].metadata.name}'); echo "bad pod: $BAD"
echo "$BAD" > ~/.local/state/lab-demo/bad-pod.name
demo-window start bad-pod
curl -s -X PUT -d "$BAD" http://10.0.0.95:30092/v1/kv/chaos/customers-service/fail-instance; echo
sleep 6   # the app polls its chaos toggles every 5 s
U=http://10.0.0.95:30097
for i in $(seq 1 120); do curl -s -o /dev/null -w '%{http_code}\n' $U/api/customer/owners/1; sleep 0.25; done | sort | uniq -c
kubectl -n lab-environment exec deploy/waypoint -- pilot-agent request GET stats | grep -E 'customers-service.*outlier_detection.ejections_(active|enforced_total)'
kubectl -n lab-environment exec "$BAD" -- curl -s -o /dev/null -w 'bad pod readiness %{http_code}\n' localhost:8081/actuator/health/readiness
demo-window stop bad-pod
demo-reset bad-pod
demo-evidence bad-pod
```
(The reset runs before the evidence on purpose, as in 05: the toggle must
not stay on while the evidence queries run.)

## Expected result
`120 200`. The waypoint shows `ejections_active 1` on the stable cluster;
the bad pod is still Ready (`200`). Reset prints `baseline OK`.

## Evidence
- **Envoy (stats):** peak `outlier_detection_ejections_active` ≥ 1 on the
  customers-service cluster.
- **Envoy (access log):** requests with `attempts > 1` exist, and no
  customers-service request failed.
- **App:** the bad pod's own count of 503 answers.

## Talking points
- **The pod is Ready the whole time.** Kubernetes sees nothing wrong — its
  probes pass. Only the data plane, watching real responses, can tell.
- Two mechanisms, two jobs: the retry (`retryOn: …,503`, a different host
  each attempt) protects the request in flight; outlier detection
  (5 consecutive 5xx → 30 s out, longer on each repeat) protects the ones
  after it. Each waypoint replica ejects on its own evidence.
- `maxEjectionPercent: 50` — with 5 pods at most 2 go at once; a
  single-replica service is never ejected (floors to 0). A bad canary alone
  in its subset is never ejected either (10).
- 503 is retried, 500 is not (10): a 500 is a bug, and retrying it would
  hide it on another pod — here, hiding a sick instance is the point.
- **Fault injection could not have shown this.** An injected abort is a
  local reply in the waypoint; it never reaches a pod, so it never counts
  toward ejection (phase I, measured). A real bad upstream was needed.

## Reset
Already run inside the commands; `demo-reset bad-pod` is safe to repeat.
````

- [ ] **Step 6: Commit**

```bash
git add k3s/apps/lab-environment/demo/scenarios/bad-pod.sh k3s/apps/lab-environment/tests/test-demo-helpers.sh docs/demo/14-bad-pod.md
git commit -m "demo: add scenario 14, one bad pod ejected by outlier detection"
```

---

### Task 4: Ledger C — measure retry compounding across hops

**Files:**
- Modify: `k3s/apps/lab-environment/k8s/resilience.yaml:8-20` (comment), and — only if the measurement exceeds 3 — each DestinationRule's `connectionPool.http`

**Interfaces:**
- Consumes: visits' `fail-instance` (Task 2).
- Produces: a measured attempts-per-external-request figure in the ledger and in `resilience.yaml`.

- [ ] **Step 1: Measure on both paths that reach visits**

```bash
V=$(kubectl -n lab-environment get pods -l app=visits-service -o jsonpath='{.items[0].metadata.name}')
q() { curl -s -G http://10.0.0.95:30093/api/v1/query --data-urlencode "query=sum(http_server_requests_seconds_count{pod=\"$V\", status=\"503\"})" | jq -r '.data.result[0].value[1] // 0'; }
curl -s -X PUT -d "$V" http://10.0.0.95:30092/v1/kv/chaos/visits-service/fail-instance; sleep 20
a=$(q); for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners/6/visits; done | sort | uniq -c; sleep 35; b=$(q)
echo "customers path: $(( (${b%.*} - ${a%.*}) / 10 )) visits attempts per request"
a=$b; for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/gateway/owners/6; done | sort | uniq -c; sleep 35; b=$(q)
echo "gateway path: $(( (${b%.*} - ${a%.*}) / 10 )) visits attempts per request"
curl -s -X PUT -d false http://10.0.0.95:30092/v1/kv/chaos/visits-service/fail-instance
demo-reset preflight
```
The generator never calls visits paths, so the counts are the page's alone. Also read the access log's `attempts` and codes per hop for those minutes (Loki, `{service="istio-proxy"} | json | authority=~"(customers|visits)-service.*"`). Record: attempts per path, the status customers-service returns upstream when visits answers 503 (this decides whether the outer hop retries too), and the client-facing code.

- [ ] **Step 2: Apply the exit rule**
  - **≤ 3 on both paths:** rewrite `resilience.yaml`'s comment block (lines 8-20) with the measured numbers and the reason compounding stops (for example: "customers-service turns visits' 503 into a 500, which is not in retryOn, so the outer hop does not retry: measured 3 attempts at visits per request, 2026-09-2x"). No policy change.
  - **> 3:** add to every DestinationRule's `connectionPool.http` a concurrent-retry cap `maxRetries: 10` (per waypoint replica; the generator plus a demo peak need far fewer), rewrite the comment with before/after numbers, push (ask the owner), re-run Step 1, record the new figure.

- [ ] **Step 3: Commit** (`resilience.yaml` only)

```bash
git commit -m "lab: record measured retry compounding across hops (ledger C)" -- k3s/apps/lab-environment/k8s/resilience.yaml
```

---

### Task 5: Scenario 15 — header-triggered fault injection

**Files:**
- Create: `k3s/apps/lab-environment/demo/patches/fault-injection.patch`
- Create: `k3s/apps/lab-environment/demo/scenarios/fault-injection.sh`
- Create: `docs/demo/15-fault-injection.md`
- Modify: `k3s/apps/lab-environment/demo/lib.sh:138-144` (`routing_baseline` names a `fault` rule)
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

**Interfaces:**
- Consumes: `CUST_SEL`, `loki_count`, `prom_delta`, `routing_baseline`.
- Produces: `evidence_fault_injection`; `routing_baseline` output token `fault`.

- [ ] **Step 1: Write the patch** — edit `resilience.yaml`, inserting as the first entries of the customers-service VirtualService's `http:` (right after the "Pinned to the stable subset" comment):

```yaml
    # Demo-only fault injection (docs/demo/15): requests carrying x-fault get
    # a delay or an abort; everything else falls through to the stable pin.
    - match:
        - headers:
            x-fault:
              exact: delay
      fault:
        delay:
          percentage:
            value: 100
          fixedDelay: 2s
      route:
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: stable
      timeout: 3s
      retries:
        attempts: 2
        perTryTimeout: 1s
        retryOn: connect-failure,refused-stream,unavailable,503
    - match:
        - headers:
            x-fault:
              exact: abort
      fault:
        abort:
          percentage:
            value: 100
          httpStatus: 503
      route:
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: stable
      timeout: 3s
      retries:
        attempts: 2
        perTryTimeout: 1s
        retryOn: connect-failure,refused-stream,unavailable,503
```
Then capture and restore:
```bash
git diff -- k3s/apps/lab-environment/k8s/resilience.yaml > k3s/apps/lab-environment/demo/patches/fault-injection.patch
git checkout -- k3s/apps/lab-environment/k8s/resilience.yaml
git apply --check k3s/apps/lab-environment/demo/patches/fault-injection.patch && echo applies
```

- [ ] **Step 2: Write the failing tests** — a fixture next to the other VS fixtures (after line 60):

```bash
jq '.spec.http = [{"match":[{"headers":{"x-fault":{"exact":"abort"}}}],"fault":{"abort":{"httpStatus":503}},"route":[{"destination":{"subset":"stable"}}]}] + .spec.http' "$FAKE_VS_PINNED" > "$WORK/vs-fault.json"
```
After the `reset names a leftover header rule` check:
```bash
FAKE_VS=$WORK/vs-fault.json check "reset names a leftover fault rule" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "off the stable pin: header match+fault"
```
Before `# --- runbook pages`:
```bash
# 15: exactly the marked requests were delayed / aborted; aborts never
# reached a pod; the generator never noticed.
cp "$DEMO/scenarios/fault-injection.sh" "$DEMO_SCENARIO_DIR/"
win fault-injection 1000 1300
cat > "$WORK/hook15" <<'EOF'
#!/bin/bash
case "$1" in
  *".*DI.*"*) val "${D15:-10}" ;;
  *".*FI.*"*) val "${A15:-10}" ;;
  *"envoy_cluster_upstream_rq{"*"time=1000"*) val 4 ;;
  *"envoy_cluster_upstream_rq{"*"time=1320"*) val "${U15:-4}" ;;
  *"traffic-generator"*'!~'*) val 0 ;;
  *"traffic-generator"*) val 300 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook15"
FAKE_CURL_HOOK=$WORK/hook15 check "15 passes: 10 delayed, 10 aborted locally" 0 "$DEMO/demo-evidence" fault-injection
A15=11 FAKE_CURL_HOOK=$WORK/hook15 check "15 fails when an unmarked request was aborted" 1 "$DEMO/demo-evidence" fault-injection
U15=9 FAKE_CURL_HOOK=$WORK/hook15 check "15 fails when an abort reached a pod" 1 "$DEMO/demo-evidence" fault-injection
```

- [ ] **Step 3: Run to verify they fail** — the fault-rule reset check fails (output says `header match` only), the three `15` checks fail on the unknown scenario.

- [ ] **Step 4: Implement** — in `routing_baseline`'s jq array add an entry after the header-match one:

```bash
                        (if any(.match[]?; .headers) then "header match" else empty end),
                        (if .fault then "fault" else empty end) ]
```

`fault-injection.sh`:

```bash
# 15 — header-triggered fault injection: only marked requests are delayed or
# aborted, and an abort is a local reply that never reaches a pod.
N_DELAY=10 N_ABORT=10   # the page sends exactly these

evidence_fault_injection() {
  local di fi up5 gtotal gbad
  settle
  di=$(loki_count "$CUST_SEL | response_flags=~\".*DI.*\"" "$WINDOW_START" "$WINDOW_END")
  fi=$(loki_count "$CUST_SEL | response_flags=~\".*FI.*\"" "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "waypoint delayed $di (want $N_DELAY) and aborted $fi (want $N_ABORT) requests - exactly the marked ones" \
    [ "$di" -eq "$N_DELAY" -a "$fi" -eq "$N_ABORT" ]
  up5=$(prom_delta 'envoy_cluster_upstream_rq{job="envoy-stats", cluster_name=~".*customers-service.*", response_code_class="5xx"}')
  rec_if envoy "5xx answered by customers-service pods in the window: $up5 (want 0 - the $N_ABORT aborts were local replies)" [ "$up5" -eq 0 ]
  gtotal=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  gbad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  rec_if app "generator: $gbad non-200 of $gtotal (want 0 of > 0)" [ "$gbad" -eq 0 -a "$gtotal" -gt 0 ]
}
```
(No `reset_fault_injection`: the page's revert undoes it and `routing_baseline` verifies it.)

- [ ] **Step 5: Run the tests** — `ALL PASS`.

- [ ] **Step 6: Probe the mechanism live** (spec checks 4 and 5) — apply the patch as a real `demo:` commit (ask the owner), run the page's curls by hand, and record: the delay requests' client code and time (does the 2 s delay beat the 1 s per-try timeout?), their `response_flags` and `attempts`; the abort requests' code, flags and `attempts` (is the local 503 retried?); whether `response_flags` for a delayed request is `DI` alone or combined (e.g. `DI,UT`) — the evidence regex must match what is logged. Revert and push. Write the page's expected results from these measurements, not from the phase I notes.

- [ ] **Step 7: Write `docs/demo/15-fault-injection.md`** — structure as 11's page. Commands:

````markdown
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/fault-injection.patch
git --no-pager diff
git commit -m "demo: inject faults into customers-service for marked requests" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
U=http://10.0.0.95:30097
# Both waypoint replicas must have the new route before the window opens.
ok=0; until [ $ok -ge 10 ]; do if [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'x-fault: abort' $U/api/customer/owners/1)" != 200 ]; then ok=$((ok + 1)); else ok=0; fi; sleep 0.5; done
sleep 20   # quiet gap: keeps the warm-up out of the window
demo-window start fault-injection
echo "delay:";    for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'x-fault: delay' $U/api/customer/owners/1; done
echo "abort:";    for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' -H 'x-fault: abort' $U/api/customer/owners/1; done | sort | uniq -c
echo "unmarked:"; for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' $U/api/customer/owners/1; done | sort | uniq -c
sleep 10   # let the window's last access-log lines land inside it
demo-window stop fault-injection
demo-evidence fault-injection
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
demo-reset fault-injection
```
````
Expected result, evidence and talking points written from Step 6's measurements. Talking points must include: the blast radius is exactly the marked requests (the generator never sends `x-fault`); the header works only on `/api/customer/**` (the aggregation path drops it — 11); an abort never reaches a pod, so it cannot trip outlier detection (why 14 needed a real bad pod); whatever Step 6 measured about delay vs the per-try timeout and about retrying a local 503.

- [ ] **Step 8: Commit**

```bash
git add k3s/apps/lab-environment/demo/patches/fault-injection.patch k3s/apps/lab-environment/demo/scenarios/fault-injection.sh k3s/apps/lab-environment/demo/lib.sh k3s/apps/lab-environment/tests/test-demo-helpers.sh docs/demo/15-fault-injection.md
git commit -m "demo: add scenario 15, header-triggered fault injection"
```

---

### Task 6: Scenario 17 — network faults on a dependency through Toxiproxy

**Files:**
- Create: `k3s/apps/lab-environment/demo/patches/toxiproxy.patch` (touches `k8s/toxiproxy.yaml`, `k8s/authz.yaml`, `k8s/visits-service.yaml`)
- Create: `k3s/apps/lab-environment/demo/scenarios/toxiproxy.sh`
- Create: `docs/demo/17-toxiproxy.md`
- Modify: `k3s/apps/lab-environment/demo/lib.sh` (new `toxiproxy_baseline`, called from `baseline_check`)
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

**Interfaces:**
- Produces: `toxiproxy_baseline` (non-zero and prints what is left); `evidence_toxiproxy`, `reset_toxiproxy`.

- [ ] **Step 1: Write the patch** — edit the three files, then capture with `git diff` and restore with `git checkout`, as in Task 5 Step 1.

`toxiproxy.yaml` — prepend a ServiceAccount and a ConfigMap:

```yaml
# Demo-only (docs/demo/17): its own identity, so postgres/redis can admit it
# by principal for exactly as long as the demo lasts.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: toxiproxy
  namespace: lab-environment
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: toxiproxy-config
  namespace: lab-environment
data:
  toxiproxy.json: |
    [
      {"name": "postgres", "listen": "0.0.0.0:5432", "upstream": "postgres:5432", "enabled": true},
      {"name": "redis", "listen": "0.0.0.0:6379", "upstream": "redis:6379", "enabled": true}
    ]
---
```
In the Deployment's pod spec add `serviceAccountName: toxiproxy`, a `volumes` entry `{name: config, configMap: {name: toxiproxy-config}}`; on the container `args: ["-host=0.0.0.0", "-config=/config/toxiproxy.json"]`, `volumeMounts: [{name: config, mountPath: /config}]`, and `limits.cpu: 200m` (25m would throttle visits' DB traffic). In the Service add ports `{name: postgres, port: 5432, targetPort: 5432}` and `{name: redis, port: 6379, targetPort: 6379}`.

`authz.yaml` — add `- cluster.local/ns/lab-environment/sa/toxiproxy` to the principals of `postgres-clients` and `redis-clients`.

`visits-service.yaml` — after the `SPRING_CLOUD_CONSUL_PORT` env entry:

```yaml
            # Demo-only (docs/demo/17): route postgres and redis through
            # toxiproxy. Env beats the Consul KV values (data.db.host,
            # data.redis.host), which stay untouched.
            - name: DATA_DB_HOST
              value: "toxiproxy"
            - name: DATA_REDIS_HOST
              value: "toxiproxy"
```

- [ ] **Step 2: Write the failing tests** — in the kubectl stub, before the generic `*" get deploy "*)` line:

```bash
  *"get deploy visits-service -o jsonpath"*"env"*) echo "${FAKE_VISITS_ENV:-TZ SPRING_CLOUD_CONSUL_HOST SPRING_CLOUD_CONSUL_PORT DATA_DB_PASSWORD}" ;;
  *"get authorizationpolicy postgres-clients redis-clients"*) echo "{\"items\":[{\"spec\":{\"rules\":[{\"from\":[{\"source\":{\"principals\":[\"cluster.local/ns/lab-environment/sa/visits-service\"${FAKE_TOXI_PRINCIPAL:+,\"cluster.local/ns/lab-environment/sa/toxiproxy\"}]}}]}]}}]}" ;;
```
After the fault-rule reset check:
```bash
FAKE_VISITS_ENV="TZ DATA_DB_HOST DATA_REDIS_HOST" check "reset fails while visits still points at toxiproxy" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "visits-service still points at toxiproxy"
FAKE_TOXI_PRINCIPAL=1 check "reset fails while postgres/redis still admit toxiproxy" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "still admit sa/toxiproxy"
```
Before `# --- runbook pages`:
```bash
# 17: the mesh's 1 s per-try timeout cut the toxic's latency on visits.
cp "$DEMO/scenarios/toxiproxy.sh" "$DEMO_SCENARIO_DIR/"
win toxiproxy 1000 1300
cat > "$WORK/hook17" <<'EOF'
#!/bin/bash
case "$1" in
  *'response_flags="UT"'*) res "{\"metric\":{\"upstream_cluster\":\"inbound-vip|8082|http|visits-service.lab-environment.svc.cluster.local;\"},\"value\":[0,\"${T17:-6}\"]}" ;;
  *"http_server_requests_seconds_max"*) val 2.01 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook17"
FAKE_CURL_HOOK=$WORK/hook17 check "17 passes: visits timed out at the mesh" 0 "$DEMO/demo-evidence" toxiproxy
T17=0 FAKE_CURL_HOOK=$WORK/hook17 check "17 fails without an upstream timeout on visits" 1 "$DEMO/demo-evidence" toxiproxy
```
(If Step 6's probe finds a better app metric than `http_server_requests_seconds_max`, change it in the hook and in `toxiproxy.sh` together.)

- [ ] **Step 3: Run to verify they fail** — the two reset checks and the two `17` checks fail.

- [ ] **Step 4: Implement** — `lib.sh`, after `wait_canary_gone`:

```bash
# --- dependency chaos (2c) ---------------------------------------------------
# 17 routes visits' postgres/redis through toxiproxy and lets postgres/redis
# admit toxiproxy's identity - both must be gone after the page's revert.
toxiproxy_baseline() {
  local bad=0 envs n
  envs=$(kubectl -n "$NS" get deploy visits-service -o jsonpath='{.spec.template.spec.containers[0].env[*].name}')
  case " $envs " in *" DATA_DB_HOST "*|*" DATA_REDIS_HOST "*)
    echo "visits-service still points at toxiproxy (env: $envs)"; bad=1 ;; esac
  if ! n=$(kubectl -n "$NS" get authorizationpolicy postgres-clients redis-clients -o json \
      | jq '[.items[].spec.rules[].from[].source.principals[]? | select(endswith("/sa/toxiproxy"))] | length'); then
    echo "postgres/redis authorization policies not read"; bad=1
  elif [ "$n" != 0 ]; then
    echo "postgres/redis still admit sa/toxiproxy"; bad=1
  fi
  return $bad
}
```
and in `baseline_check`, after `routing_baseline || bad=1`: `toxiproxy_baseline || bad=1`.

`toxiproxy.sh`:

```bash
# 17 — network faults the app did not opt into: toxiproxy between
# visits-service and its data stores. The mesh's 1 s per-try timeout is the
# backstop while the app's own timeouts are longer (redis 2 s, Hikari 30 s).
evidence_toxiproxy() {
  local ut n slow
  settle
  ut=$(loki_by upstream_cluster '{service="istio-proxy"} | json | __error__="" | response_flags="UT"' "$WINDOW_START" "$WINDOW_END")
  echo "$ut" | sed 's/^/      /'
  n=$(echo "$ut" | awk '/visits-service/ { s += $1 } END { print s + 0 }')
  rec_if envoy "upstream timeouts (UT, 1 s per-try) against visits-service: $n (want > 0)" [ "$n" -gt 0 ]
  slow=$(prom "max(max_over_time(http_server_requests_seconds_max{service=\"visits-service\"}[${SETTLED_RANGE}s]))" "$SETTLED_AT")
  rec_if app "visits-service's slowest request in the window: ${slow}s (want > 1 - it kept waiting after the mesh gave up)" \
    awk "BEGIN { exit !(\"$slow\" != \"none\" && $slow + 0 > 1) }"
}

reset_toxiproxy() {
  kubectl -n "$NS" rollout status deploy/visits-service --timeout=6m
}
```

- [ ] **Step 5: Run the tests** — `ALL PASS`.

- [ ] **Step 6: Probe the mechanism live** (spec check 7) — apply the patch as a real `demo:` commit (ask the owner), then:

```bash
kubectl -n lab-environment rollout status deploy/visits-service --timeout=6m
kubectl -n lab-environment exec deploy/toxiproxy -- /toxiproxy-cli list
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/customer/owners/6/visits; done
kubectl -n lab-environment exec deploy/toxiproxy -- /toxiproxy-cli toxic add -t latency -a latency=1500 redis
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/customer/owners/6/visits; done
kubectl -n lab-environment exec deploy/toxiproxy -- /toxiproxy-cli toxic remove -n latency_downstream redis
kubectl -n lab-environment exec deploy/toxiproxy -- /toxiproxy-cli toxic add -t timeout -a timeout=0 postgres
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://10.0.0.95:30097/api/customer/owners/6/visits; done
kubectl -n lab-environment exec deploy/toxiproxy -- /toxiproxy-cli toxic remove -n timeout_downstream postgres
```
Record: that the CLI exists at that path in the image (else call the API on `:8474` from a pod), the toxic names it prints, each step's codes and times, the ztunnel log lines on oracle2 for visits → toxiproxy → postgres (`kubectl -n istio-system logs <ztunnel pod on vps-oracle2> --since=5m | grep toxiproxy`), and the app metric that shows the long wait. Whether visits recovers after the postgres black hole is removed, or only after the revert's rollout, goes into the talking points. Revert and push.

- [ ] **Step 7: Write `docs/demo/17-toxiproxy.md`** — the Step 6 sequence inside `demo-window start/stop toxiproxy`, preceded by the apply/commit/push/sync-wait lines in the form of Task 5 Step 7 plus `kubectl -n lab-environment rollout status deploy/visits-service --timeout=6m`, and followed by `demo-evidence toxiproxy`, the `git revert` + push + sync wait, and `demo-reset toxiproxy`. Expected result from Step 6. Talking points: network faults vs 05's cooperative app toggle; the per-try timeout as the backstop (redis 2 s, Hikari 30 s); while the proxy sits in the path postgres sees toxiproxy's identity — least privilege is weaker for exactly as long as the demo lasts, and `demo-reset` refuses to call the lab healthy until the grant is gone; Toxiproxy is not resident because production would not have it.

- [ ] **Step 8: Commit**

```bash
git add k3s/apps/lab-environment/demo/patches/toxiproxy.patch k3s/apps/lab-environment/demo/scenarios/toxiproxy.sh k3s/apps/lab-environment/demo/lib.sh k3s/apps/lab-environment/tests/test-demo-helpers.sh docs/demo/17-toxiproxy.md
git commit -m "demo: add scenario 17, network faults through toxiproxy"
```

---

### Task 7: Resident overload protection on vets-service

**Files:**
- Create: `k3s/apps/lab-environment/k8s/ratelimit.yaml`
- Modify: `k3s/apps/lab-environment/k8s/resilience.yaml` (vets-service DestinationRule `connectionPool`)

**Interfaces:**
- Produces: `TrafficExtension/vets-service-ratelimit`; 429 + `x-envoy-ratelimited: true` for requests over the limit; `UO` (upstream overflow) 503s past the vets pool.

- [ ] **Step 1: Measure the inputs**

```bash
W=$(kubectl -n lab-environment get pods -l gateway.networking.k8s.io/gateway-name=waypoint -o jsonpath='{.items[0].metadata.name}')
kubectl -n lab-environment exec "$W" -- pilot-agent request GET server_info | jq '.command_line_options.concurrency'
curl -s -G http://10.0.0.95:30093/api/v1/query --data-urlencode 'query=sum(rate(istio_requests_total{job="envoy-stats", reporter="waypoint", destination_canonical_service="vets-service"}[10m]))' | jq -r '.data.result[0].value[1]'
```
Record concurrency `C` and vets' steady rate. Derivation (goes into the manifest comment): 2a's knee is ~30 req/s at the edge, a quarter of it `/api/vet/vets` → vets starts to queue at ~7.5 req/s. Target a total of **6 req/s**: `LIMIT = max(1, floor(6 / (2 × C)))` per worker per 1 s window (2 waypoint replicas). With `C = 1`: `LIMIT = 3`.

- [ ] **Step 2: Write `ratelimit.yaml`** (replace `<C>` with the measured value and `LIMIT` with Step 1's result):

```yaml
# Resident overload protection for vets-service - the lab's measured
# bottleneck (one replica, a 5-connection Hikari pool; 2a's load test saw
# connection waits of up to 3 s while the node still had CPU to spare).
#
# Fixed-window token bucket in Lua on the waypoint (phase L's mechanism,
# k3s/apps/hello/k8s/hello-backend-ratelimit-trafficextension.yaml). The
# bucket is per Envoy worker per waypoint replica, not global: with
# concurrency <C> and 2 replicas the effective ceiling is LIMIT x <C> x 2.
# Sized from 2a's knee: ~30 req/s at the edge, a quarter to vets = ~7.5 req/s
# where vets starts to queue; the total is kept below that, at 6 req/s.
# Steady traffic (generator ~0.33 req/s, the Lab API Down probe) is far below.
apiVersion: extensions.istio.io/v1alpha1
kind: TrafficExtension
metadata:
  name: vets-service-ratelimit
  namespace: lab-environment
spec:
  targetRefs:
    - kind: Service
      name: vets-service
  match:
    - mode: SERVER
  phase: STATS
  lua:
    inlineCode: |
      -- 3 requests per 1 s window, per worker.
      local WINDOW_MS = 1000
      local LIMIT = 3
      local window_start_ms = 0
      local count = 0

      function envoy_on_request(request_handle)
        local now_ms = request_handle:timestamp()
        if now_ms - window_start_ms >= WINDOW_MS then
          window_start_ms = now_ms
          count = 0
        end
        count = count + 1
        if count > LIMIT then
          request_handle:respond(
            {[":status"] = "429", ["x-envoy-ratelimited"] = "true"},
            "rate limit exceeded"
          )
          return
        end
      end
```

- [ ] **Step 3: Tighten vets' pool** — in `resilience.yaml`'s vets-service DestinationRule replace `connectionPool` with:

```yaml
    # Tighter than the other services: vets holds 5 DB connections, so a
    # deep queue in front of it only turns load into 3 s waits. Past 10 in
    # flight and 5 queued (per waypoint replica) Envoy fails fast with
    # 503 UO instead.
    connectionPool:
      tcp:
        maxConnections: 10
      http:
        http1MaxPendingRequests: 5
        http2MaxRequests: 10
```
Run `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh` — the patch-drift loop must still pass (the patches touch only the customers VS).

- [ ] **Step 4: Commit both, ask the owner, push**

```bash
git add k3s/apps/lab-environment/k8s/ratelimit.yaml k3s/apps/lab-environment/k8s/resilience.yaml
git commit -m "lab: resident rate limit and tight pool in front of vets-service"
git pull --ff-only && git push
```

- [ ] **Step 5: Verify the mechanism** (spec checks 1-3)

```bash
kubectl -n lab-environment exec "$W" -- pilot-agent request GET config_dump | jq -r '.. | .http_filters? // empty | map(.name) | join(" -> ")' | grep -m3 trafficextension
for i in $(seq 1 40); do curl -s -o /dev/null -D- http://10.0.0.95:30097/api/vet/vets | tr -d '\r' | awk 'NR==1{c=$2} tolower($1)=="x-envoy-ratelimited:"{r=$2} END{print c, (r ? "ratelimited" : "-")}'; done | sort | uniq -c
```
Expected: the Lua filter in the vets-service chain, after `rbac`; a mix of `200 -` and `429 ratelimited` at the client (the header survives api-gateway). If the client sees 429 without the header, or a 500, record what api-gateway does with it — it changes 16's evidence and page.

- [ ] **Step 6: Steady-state gate (Review Focus 4)** — wait 10 minutes, then:

```bash
curl -s -G http://10.0.0.95:30094/api/datasources/proxy/uid/loki/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({service="istio-proxy", response_code="429"} [10m]))' | jq -r '.data.result[0].value[1] // 0'
kubectl -n lab-environment logs deploy/traffic-generator --since=10m | awk '$2 != "200"' | wc -l
```
Expected: `0` and `0`; `Lab API Down` inactive in the vps_oracle Grafana. Anything else: raise `LIMIT`, re-derive, re-push.

---

### Task 8: Scenario 16 — rate limiting, and its baseline check

**Files:**
- Create: `k3s/apps/lab-environment/demo/scenarios/rate-limit.sh`
- Create: `docs/demo/16-rate-limit.md`
- Modify: `k3s/apps/lab-environment/demo/lib.sh` (`baseline_check`: the TrafficExtension exists)
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

**Interfaces:**
- Produces: `evidence_rate_limit`; baseline line `vets-service-ratelimit TrafficExtension missing`.

- [ ] **Step 1: Write the failing tests** — kubectl stub, before the generic deploy case:

```bash
  *"get trafficextension vets-service-ratelimit"*) [ -n "${FAKE_NO_RATELIMIT:-}" ] || echo "trafficextension.extensions.istio.io/vets-service-ratelimit" ;;
```
After the toxiproxy reset checks:
```bash
FAKE_NO_RATELIMIT=1 check "reset fails when the resident rate limit is gone" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "vets-service-ratelimit TrafficExtension missing"
```
Before `# --- runbook pages`:
```bash
# 16: the burst was limited at the waypoint; vets itself saw only the
# admitted requests; steady traffic was untouched.
cp "$DEMO/scenarios/rate-limit.sh" "$DEMO_SCENARIO_DIR/"
win rate-limit 1000 1300
cat > "$WORK/hook16" <<'EOF'
#!/bin/bash
case "$1" in
  *"sum by (pod_name)"*) res "{\"metric\":{\"pod_name\":\"waypoint-a\"},\"value\":[0,\"${L16:-20}\"]},{\"metric\":{\"pod_name\":\"waypoint-b\"},\"value\":[0,\"18\"]}" ;;
  *"vets-service"*"time=1000"*) val 100 ;;
  *"vets-service"*"time=1320"*) val "${V16:-125}" ;;
  *"traffic-generator"*'!~'*) val "${G16:-0}" ;;
  *"traffic-generator"*) val 300 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook16"
FAKE_CURL_HOOK=$WORK/hook16 check "16 passes: 38 limited, vets saw only the rest" 0 "$DEMO/demo-evidence" rate-limit
has "$WORK/out" "waypoint-a 20"
V16=170 FAKE_CURL_HOOK=$WORK/hook16 check "16 fails when every request reached vets" 1 "$DEMO/demo-evidence" rate-limit
G16=3 FAKE_CURL_HOOK=$WORK/hook16 check "16 fails when steady traffic was limited" 1 "$DEMO/demo-evidence" rate-limit
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement** — in `baseline_check`, after `toxiproxy_baseline || bad=1`:

```bash
  kubectl -n "$NS" get trafficextension vets-service-ratelimit -o name 2>/dev/null | grep -q . \
    || { echo "vets-service-ratelimit TrafficExtension missing"; bad=1; }
```

`rate-limit.sh`:

```bash
# 16 — rate limiting at the waypoint: a burst to /api/vet/vets is cut to the
# resident limit; vets-service itself only sees what was admitted.
SENT=60   # the page sends exactly these

evidence_rate_limit() {
  local per total own gtotal gbad
  settle
  per=$(loki_by pod_name '{service="istio-proxy", response_code="429"} | json | __error__="" | authority=~"vets-service.*"' "$WINDOW_START" "$WINDOW_END")
  echo "$per" | awk '{ printf "      %s %s\n", $2, $1 }'
  total=$(echo "$per" | awk '{ s += $1 } END { print s + 0 }')
  rec_if envoy "429 from the waypoint's Lua limiter: $total of the $SENT sent (want > 0), per replica above" [ "$total" -gt 0 ]
  own=$(prom_delta 'http_server_requests_seconds_count{service="vets-service", uri!~"/actuator.*"}')
  gtotal=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  gbad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  rec_if app "vets-service counted $own requests itself (want < $SENT - the limited ones never arrived); generator $gbad non-200 of $gtotal (want 0)" \
    [ "$own" -lt "$SENT" -a "$gbad" -eq 0 -a "$gtotal" -gt 0 ]
}
```
(vets' own count includes the generator's few vets calls in the window; `< SENT` still holds when a third or more of the burst is limited — confirm with Step 5's real run.)

- [ ] **Step 4: Run the tests** — `ALL PASS`.

- [ ] **Step 5: Write `docs/demo/16-rate-limit.md`** — commands:

````markdown
```bash
demo-window start rate-limit
U=http://10.0.0.95:30097
for i in $(seq 1 60); do curl -s -o /dev/null -D- $U/api/vet/vets | tr -d '\r' | awk 'NR==1{c=$2} tolower($1)=="x-envoy-ratelimited:"{r=$2} END{print c, (r ? "ratelimited" : "-")}'; done | sort | uniq -c
sleep 10
demo-window stop rate-limit
demo-evidence rate-limit
kubectl -n lab-environment get trafficextension vets-service-ratelimit -o jsonpath='{.spec.lua.inlineCode}' | head -3
```
````
Run it once for real and write Expected result from that run. Talking points: the limit is derived from the measured bottleneck, not guessed; a 429 is cheap and immediate, the alternative was a 3 s queue for a DB connection; the bucket is local — per worker, per replica — so the real ceiling is LIMIT × workers × replicas, and a global limit needs an external rate-limit service (not built: EnvoyFilter on an ambient waypoint has "very very limited support"); authorization runs before the limiter (`rbac` precedes the Lua filter), so denied callers never spend quota; the limiter sees only traffic through the waypoint — a direct pod call would bypass it, and the L4 policy (only the waypoint may call vets pods) is what closes that. Reset: nothing to undo; `demo-reset rate-limit` verifies the baseline, including the limiter's presence.

- [ ] **Step 6: Commit**

```bash
git add k3s/apps/lab-environment/demo/scenarios/rate-limit.sh k3s/apps/lab-environment/demo/lib.sh k3s/apps/lab-environment/tests/test-demo-helpers.sh docs/demo/16-rate-limit.md
git commit -m "demo: add scenario 16, rate limiting at the waypoint"
```

---

### Task 9: 08 rewritten — capacity and overload protection (group B 5 and 6, ledger D)

**Files:**
- Modify: `k3s/apps/lab-environment/demo/scenarios/load-test.sh` (whole file)
- Modify: `docs/demo/08-load-test.md`
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`
- Possibly modify: `k3s/apps/lab-environment/k8s/vets-service.yaml`, `k8s/api-gateway.yaml` (ledger D exit rule)

**Interfaces:**
- Produces: `evidence_load_test` with pieces: envoy minute table (epoch join), envoy shed count, envoy admitted P99, cadvisor node-not-saturated, app vets Hikari; notes: throttling alert, vets peak working set.

- [ ] **Step 1: Write the failing tests** — before `# --- runbook pages`:

```bash
# 08: shed fast, admitted P99 flat, node and pool out of saturation; the
# minute table survives a run across UTC midnight.
cp "$DEMO/scenarios/load-test.sh" "$DEMO_SCENARIO_DIR/"
win load-test 86100 86520
mr() { printf '{"data":{"result":[{"metric":{},"values":[[86280,"%s"],[86340,"%s"],[86400,"%s"],[86460,"%s"],[86520,"%s"]]}]}}' "$@"; }
export -f mr
cat > "$WORK/hook08" <<'EOF'
#!/bin/bash
case "$1" in
  *"query_range"*"histogram_quantile"*) mr 70 80 90 95 99 ;;
  *"query_range"*) mr 10 20 40 60 80 ;;
  *'response_code="429"'*) val "${S08:-500}" ;;
  *'response_code="200"'*) val "${P08:-180}" ;;
  *'id="/"'*) val "${N08:-1.1}" ;;
  *"cfs_throttled"*) res '{"metric":{"pod":"vets-service-x"},"value":[0,"0.1"]}' ;;
  *"hikaricp_connections_acquire_seconds_max"*) res "{\"metric\":{\"service\":\"vets-service\"},\"value\":[0,\"${H08:-0.1}\"]}" ;;
  *"container_memory_working_set_bytes"*) val 402653184 ;;
  *"/api/prometheus/grafana"*) echo '{"data":{"alerts":[]}}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook08"
FAKE_CURL_HOOK=$WORK/hook08 check "08 passes: shed, flat, unsaturated" 0 "$DEMO/demo-evidence" load-test
for m in "23:58" "23:59" "00:00" "00:01" "00:02"; do has "$WORK/out" "      $m "; done
N08=1.8 FAKE_CURL_HOOK=$WORK/hook08 check "08 fails when the node saturated" 1 "$DEMO/demo-evidence" load-test
S08=0 FAKE_CURL_HOOK=$WORK/hook08 check "08 fails when nothing was shed" 1 "$DEMO/demo-evidence" load-test
H08=2.9 FAKE_CURL_HOOK=$WORK/hook08 check "08 fails when vets still queued for connections" 1 "$DEMO/demo-evidence" load-test
```

- [ ] **Step 2: Run to verify they fail** (the old script has no shed piece and prints the old table).

- [ ] **Step 3: Rewrite `load-test.sh`**

```bash
# 08 — capacity and overload protection: the same stepped load as 2a, now
# against vets-service's resident limiter and tight pool. Excess must fail
# fast, admitted requests must stay fast, and nothing may saturate.
P99_MAX=400   # ms, admitted (200) requests over the whole run - 2a peaked at 842 unprotected

range_minutes() { # range_minutes <query> -> "<epoch> <value floored>" per minute
  curl -sf -G "$PROM/api/v1/query_range" --data-urlencode "query=$1" \
    --data-urlencode "start=$WINDOW_START" --data-urlencode "end=$WINDOW_END" --data-urlencode step=60 \
    | jq -r '.data.result[0].values[]? | "\(.[0]) \(.[1] | tonumber | floor)"'
}

evidence_load_test() {
  local range=$(( WINDOW_END - WINDOW_START )) rps p99 pts shed adm node thr acq wait svc ws alert
  local API='job="envoy-stats", reporter="waypoint", destination_canonical_service="api-gateway"'
  rps=$(range_minutes "sum(rate(istio_requests_total{$API}[1m]))")
  p99=$(range_minutes "histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{$API}[1m])))")
  echo "      minute  rps   p99(ms)"
  # Join on the epoch, not on HH:MM, so a run across UTC midnight keeps its rows and order.
  join <(echo "$rps" | sort -k1,1) <(echo "$p99" | sort -k1,1) | sort -n \
    | while read -r t r p; do printf '      %s  %4s  %s\n' "$(date -u -d "@$t" +%H:%M)" "$r" "$p"; done
  pts=$(echo "$p99" | grep -c . || true)
  rec_if envoy "waypoint RPS and P99 per minute over the run: $pts points (want >= 5)" [ "$pts" -ge 5 ]

  shed=$(loki_count '{service="istio-proxy"} | json | __error__="" | authority=~"vets-service.*" | response_code="429" or response_flags=~".*UO.*"' "$WINDOW_START" "$WINDOW_END")
  rec_if envoy "vets-service requests shed fast (429 limiter / UO pool overflow): $shed (want > 0)" [ "$shed" -gt 0 ]
  adm=$(prom "histogram_quantile(0.99, sum by (le) (rate(istio_request_duration_milliseconds_bucket{$API, response_code=\"200\"}[${range}s])))" "$WINDOW_END")
  rec_if envoy "admitted (200) requests' P99 over the whole run: ${adm} ms (want <= $P99_MAX)" \
    awk "BEGIN { exit !(\"$adm\" != \"none\" && $adm + 0 <= $P99_MAX) }"

  node=$(prom "max_over_time(sum(rate(container_cpu_usage_seconds_total{id=\"/\", node=\"vps-oracle2\"}[1m]))[${range}s:30s])" "$WINDOW_END")
  thr=$(prom_vector pod "topk(1, max by (pod) (max_over_time((rate(container_cpu_cfs_throttled_periods_total{namespace=\"$NS\", container!=\"\"}[1m]) / rate(container_cpu_cfs_periods_total{namespace=\"$NS\", container!=\"\"}[1m]))[${range}s:30s])))" "$WINDOW_END")
  rec_if cadvisor "peak node CPU $node of 2 cores (want < 1.6: protection kept the node out of saturation); most throttled: ${thr:-none}" \
    awk "BEGIN { exit !(\"$node\" != \"none\" && $node + 0 < 1.6) }"

  acq=$(prom_vector service "topk(1, max by (service) (max_over_time(hikaricp_connections_acquire_seconds_max[${range}s])))" "$WINDOW_END")
  wait=${acq%% *}; svc=${acq#* }
  rec_if app "longest wait for a DB connection: ${wait:-none}s ($svc) (want < 0.5 - 2a measured 2.99 unprotected)" \
    awk "BEGIN { exit !(\"${wait:-none}\" != \"none\" && ${wait:-0} + 0 < 0.5) }"

  ws=$(prom "max(max_over_time(container_memory_working_set_bytes{namespace=\"$NS\", container=\"vets-service\"}[${range}s]))" "$WINDOW_END")
  note "vets-service peak working set: $(awk "BEGIN { printf \"%d\", $ws / 1048576 }")Mi of its 512Mi limit (ledger D)"
  alert=$(curl -sf "$GRAFANA/api/prometheus/grafana/api/v1/alerts" | jq -r '[.data.alerts[] | select(.labels.alertname == "Lab CPU Throttling") | .state] | join(",")')
  note "Lab CPU Throttling alert state: ${alert:-inactive} (needs 10 min sustained)"
}

reset_load_test() {
  docker rm -f lab-k6 >/dev/null 2>&1 || true
}
```

- [ ] **Step 4: Run the tests** — `ALL PASS`.

- [ ] **Step 5: Run 08 for real** (page commands unchanged) and record the table, shed count, admitted P99, node peak, Hikari max and vets' peak working set in the ledger. If `P99_MAX` fails, read the per-minute table before touching the threshold: an admitted P99 rising with load means protection is too loose (lower `LIMIT`, Task 7), not that the threshold is too strict. Record every such decision.

- [ ] **Step 6: Ledger D exit rule** — headroom = `512Mi − vets peak working set`:
  - `< 100Mi`: add `MALLOC_ARENA_MAX: "2"` and `limits.memory: 768Mi` to `vets-service.yaml` and `api-gateway.yaml` with the comment visits-service carries (its lines 63-69), commit, ask the owner, push, rollout gate as in Task 2 Step 2.
  - `≥ 100Mi`: no change; record the measurement for the README (Task 13).

- [ ] **Step 7: Rewrite `docs/demo/08-load-test.md`** — title "08 — Load test: capacity and overload protection". Keep the commands. Rewrite Purpose (find the knee *and* show protection holding past it); Expected result (the new table; the 2a table moves under a heading "Before protection (2a, 2026-09-27)" with its numbers unchanged); Evidence (the five pieces above); Talking points — keep the open-model, wrong-hypothesis and Envoy-is-cheap points, drop "what the lab cannot show yet", and add: excess fails in milliseconds instead of queueing 3 s for a connection; the limit came from the measured knee; `UO` (pool overflow) and 429 (limiter) are two different guards; the `Lab API Down` probe path is `/api/vet/vets`, so under this load it may be limited and page — a real limiter protecting a real bottleneck, said before the run.

- [ ] **Step 8: Commit**

```bash
git add k3s/apps/lab-environment/demo/scenarios/load-test.sh k3s/apps/lab-environment/tests/test-demo-helpers.sh docs/demo/08-load-test.md
git commit -m "demo: rewrite 08 as capacity and overload protection"
```

---

### Task 10: Alert on a silent kube-state-metrics (group B 4)

**Files:**
- Modify: `k3s/apps/lab-environment/k8s/configmaps.yaml` (`alerting.yml`: new rule after `lab_oomkilled`; `lab_quota_near_limit`'s summary)
- Modify: `k3s/apps/lab-environment/k8s/grafana.yaml` (its `config-rev` annotation — `grep -n config-rev`)

- [ ] **Step 1: Confirm the scrape job name** — `curl -s http://10.0.0.95:30093/api/v1/targets | jq -r '.data.activeTargets[].labels.job' | sort -u` must list `kube-state-metrics`.

- [ ] **Step 2: Add the rule and fix the summary**

```yaml
          # Every rule above reads kube-state-metrics and has noDataState OK,
          # so a KSM outage would silence all of them at once. This one is
          # the opposite: no data is itself the alert.
          - uid: lab_ksm_down
            title: Lab KSM Down
            condition: B
            for: 3m
            noDataState: Alerting
            annotations:
              summary: "kube-state-metrics is not being scraped - the other Lab Capacity rules cannot fire while it is down"
            data:
              - refId: A
                datasourceUid: prometheus
                relativeTimeRange: {from: 300, to: 0}
                model: {refId: A, instant: true, expr: 'max(up{job="kube-state-metrics"})'}
              - refId: B
                datasourceUid: '__expr__'
                model: {refId: B, type: threshold, expression: A, conditions: [{evaluator: {type: lt, params: [1]}}]}
```
`lab_quota_near_limit` summary → `"A lab-environment-quota resource (CPU or memory requests, or any other quota item) above 90% of hard"`. Bump grafana's `config-rev` by one. Commit (`lab: alert when kube-state-metrics goes silent`), ask the owner, push.

- [ ] **Step 3: Fire it once for real** — ask the owner first. Disable selfHeal on the `kube-state-metrics` Application (`kubectl -n argocd patch application kube-state-metrics --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'` — the rule's documented trial exception), `kubectl -n kube-system scale deploy/kube-state-metrics --replicas=0`, wait until `Lab KSM Down` is `Alerting` (~3.5 min: `curl -s http://10.0.0.95:30094/api/prometheus/grafana/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname=="Lab KSM Down") | .state'`), scale back to 1, set selfHeal back to `true` the same way, then confirm `argocd app get kube-state-metrics --core` is `Synced/Healthy`, the Application's `selfHeal` reads `true`, and the alert returns to inactive. Record the times.

---

### Task 11: Investigate "Ready but not routable" (2a `UF,URX`, 2b `503 UH`)

**Files:** none planned — the outcome decides (a fix commit, or README text in Task 13).

Use `superpowers:systematic-debugging`. Exit: root cause fixed, or the window quantified and accepted in writing.

- [ ] **Step 1: Reproduce with instrumentation** — ask the owner (a rollout push). Start three recorders, then bump `lab.jerome/rollout-rev` on customers, visits and vets in one commit (`lab:` prefix — a real restart, not a demo) and push:

```bash
L=.superpowers/sdd/2026-09-28-lab-resilience-scenarios
( end=$((SECONDS+420)); while [ $SECONDS -lt $end ]; do for i in 1 2 3 4; do curl -s -o /dev/null -w "$(date -u +%T.%3N) %{http_code}\n" http://10.0.0.95:30097/api/customer/owners/1 & done; wait; sleep 0.2; done ) > $L/t11-client.log &
( end=$((SECONDS+420)); while [ $SECONDS -lt $end ]; do for w in $(kubectl -n lab-environment get pods -l gateway.networking.k8s.io/gateway-name=waypoint -o name); do echo "$(date -u +%T.%3N) $w $(kubectl -n lab-environment exec ${w#pod/} -- pilot-agent request GET clusters 2>/dev/null | grep -E 'customers-service.*::10\.[0-9.]+:8081::health_flags' | awk -F'::' '{print $2"="$4}' | sort | tr '\n' ' ')"; done; sleep 1; done ) > $L/t11-eds.log &
kubectl -n lab-environment get pods -l app=customers-service -w -o wide > $L/t11-pods.log &
```
After the rollouts finish (stop the watch with `kill %3`): `kubectl -n lab-environment get pods -l app=customers-service -o json | jq -r '.items[] | "\(.metadata.name) \(.status.podIP) \(.status.conditions[] | select(.type=="Ready") | .lastTransitionTime)"'`; Loki lines with `response_flags=~"UF.*|UH|URX.*"` for the 7 minutes with `upstream_host` and timestamps; the ztunnel log on oracle2 for the same minutes.

- [ ] **Step 2: Correlate** — for each failing request: which pod IP, that pod's Ready time, when that IP first appeared `healthy` in each waypoint's cluster list, and whether the IP belonged to a terminating pod earlier in the run (IP reuse). Put the per-request timeline table in the ledger.

- [ ] **Step 3: Decide**
  - Endpoint known to the waypoint before the path to the pod works: try a candidate (e.g. `minReadySeconds`, or a short readiness initial delay) only if a re-run shows it closes the gap; otherwise accept.
  - IP reuse: record the evidence and accept (upstream behaviour).
  - Anything fixed: commit with the before/after measurement in the message; ask the owner before the push.
  - Accepted: write the quantified window (max seconds, which hop, which flag) into the ledger for Task 13's README paragraph.

---

### Task 12: Investigate the waypoint roll dropping api-gateway's connections

**Files:**
- Modify (candidate fix): `k3s/apps/lab-environment/k8s/waypoint.yaml` (`waypoint-params`)

- [ ] **Step 1: Reproduce** — ask the owner (the waypoint Deployment is generated by istiod, not ArgoCD, so a restart is not reverted by selfHeal):

```bash
L=.superpowers/sdd/2026-09-28-lab-resilience-scenarios
( end=$((SECONDS+180)); while [ $SECONDS -lt $end ]; do curl -s -o /dev/null -w "$(date -u +%T.%3N) %{http_code}\n" http://10.0.0.95:30097/api/customer/owners/1; sleep 0.1; done ) > $L/t12-before.log &
kubectl -n lab-environment rollout restart deploy/waypoint && kubectl -n lab-environment rollout status deploy/waypoint --timeout=5m
wait; awk '$2 != 200' $L/t12-before.log | wc -l
kubectl -n lab-environment logs deploy/api-gateway --since=4m | grep -ci 'connection'
```
Run twice. Record the error counts, codes and api-gateway's log lines. If both runs show 0 errors, record "not reproduced" and close as accepted, citing 2b's single observation.

- [ ] **Step 2: Candidate fix — drain the waypoint before it exits.** In `waypoint-params`' `proxy.istio.io/config` annotation add `terminationDrainDuration: 20s` (at the same indentation as `proxyStatsMatcher:`), and in the pod `spec` add `terminationGracePeriodSeconds: 30`. Commit, ask the owner, push; confirm the new waypoint pods carry it (`kubectl -n lab-environment get pod <w> -o jsonpath='{.metadata.annotations.proxy\.istio\.io/config}'`); re-run Step 1 twice.

- [ ] **Step 3: Exit**
  - Zero errors in both runs: keep; the commit message carries before/after counts.
  - Still errors: revert Step 2, record why, and put the app-side fallback — a Spring Cloud Gateway retry filter for GET on connection errors in api-gateway (fork) — to the owner as a separate decision; do not implement it without a yes. If declined, accept in writing with the measured error count per waypoint roll.

---

### Task 13: Rehearsal, acceptance and documentation

**Files:**
- Modify: `docs/demo/README.md` (order table), `k3s/apps/lab-environment/README.md` (Resilience section), `k3s/apps/lab-environment/k8s/authz.yaml` (data-store comment: toxiproxy "is not in the data path" → add "except during docs/demo/17"), `docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md` (2c status; 2a polish row: group B done), the spec's "Implementation results"
- Create: `docs/demo/evidence/{bad-pod,fault-injection,toxiproxy,rate-limit,load-test}.txt`

- [ ] **Step 1: Update `docs/demo/README.md`'s order table** — insert after 12:

```markdown
| 14 | [One bad pod is ejected](14-bad-pod.md) | Resilience after routing; an ejection lasts 30 s |
| 15 | [Header-triggered fault injection](15-fault-injection.md) | |
| 17 | [Network faults through Toxiproxy](17-toxiproxy.md) | Two visits rollouts |
```
after 06:
```markdown
| 16 | [Rate limiting at the waypoint](16-rate-limit.md) | Rate limiting last; 08 relies on it |
```
and rename 08's row to "Load test: capacity and overload protection".

- [ ] **Step 2: Full rehearsal** — `demo-reset preflight` → `baseline OK`, then pages 14 → 15 → 17 → 16 → 08 in order with `export DEMO_SAVE_DIR=docs/demo/evidence`. Every `demo-evidence` must pass; a failure is fixed at its cause and that page re-run (record each rerun and why, as 2b did). Ask the owner before the pushes (15 and 17 push twice each).

- [ ] **Step 3: Check acceptance 6** — no `FailedCreate` / `FailedScheduling` since the rehearsal start (`kubectl -n lab-environment get events --field-selector reason=FailedCreate`, and `reason=FailedScheduling`); `Lab Pod Pending` and `Lab Quota Near Limit` inactive.

- [ ] **Step 4: Afterwards** — `demo-reset preflight` → `baseline OK`; `git log --oneline` shows each `demo:` commit paired with its revert.

- [ ] **Step 5: Write the documentation** — the lab README's Resilience paragraph gains the limiter (derivation, per-replica semantics), vets' tight pool, the fail-instance toggle, the measured ledger C figure, ledger D's outcome, and the outcomes of Tasks 11 and 12; the roadmap's 2c row becomes **Done 2026-09-2x** with links, and the 2a-polish row records group B done; the spec gets an "Implementation results" section (criteria 1-7 with PASS/FAIL and evidence, measured values, deviations and why, open findings) in 2b's shape.

- [ ] **Step 6: Commit**

```bash
git add docs/demo k3s/apps/lab-environment/README.md k3s/apps/lab-environment/k8s/authz.yaml docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md docs/superpowers/specs/2026-09-28-lab-resilience-scenarios-design.md
git commit -m "docs: record the 2c rehearsal and results"
```
(The `authz.yaml` edit is comment-only and syncs harmlessly; ask the owner before the push.)

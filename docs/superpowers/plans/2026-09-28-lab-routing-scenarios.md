# Lab Routing Scenarios (Sub-project 2b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five live-demoable routing scenarios on `lab-environment` — canary by instance ratio (09), canary by weight with a caught regression (10), header/cookie gray release (11), traffic mirroring (13), blue-green (12) — each with a runbook page, evidence functions and a verified reset.

**Architecture:** A resident "next version" slot (`customers-service-canary` at `replicas: 0`, DestinationRule subsets `stable`/`canary` by pod label `track`, VirtualService pinned to `stable`). Each scenario applies one pre-written patch from `demo/patches/`, commits it as `demo:`, pushes, and later `git revert`s it. The canary runs real fork builds (v2-good, v2-bad). Blue-green's 5-replica green is paid for by decommissioning dify on vps-oracle2 and raising the lab memory quota to 9.5Gi.

**Tech Stack:** Istio ambient (waypoint VirtualService/DestinationRule), ArgoCD, Kubernetes, bash helpers + stubbed tests, Loki/Prometheus/Grafana, Spring Boot 4 (petclinic fork, Maven), docker compose (oracle2 context).

**Spec:** [docs/superpowers/specs/2026-09-28-lab-routing-scenarios-design.md](../specs/2026-09-28-lab-routing-scenarios-design.md)

## Global Constraints

- **Ask the owner before every `git push` that touches `k3s/`** (standing rule). Batch pushes of one task into one question where possible. Lab roadmap work commits straight to `main`.
- **Other Claude sessions may commit to `main` in this checkout**: run `git status` and `git log -3` before every commit; `git pull --ff-only` before every push.
- **Confirm with the owner before**: stopping dify, disabling its NPM proxy host, running `k3s/install/agent-vps-oracle2/install.sh` (restarts k3s-agent), pushing the fork branch to GitHub.
- Committed text (messages, comments, docs) in English; one logical change per commit; every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Canary slot: Deployment `customers-service-canary`; pod labels `app: customers-service`, `track: canary`, `version: v2`; stable pods gain `track: stable`, `version: v1`; stable's selector stays `app: customers-service` (immutable).
- Lab quota `requests.memory: 9.5Gi` (9728Mi); node inequality **allocatable ≥ 9728 + 640 = 10368Mi** (640Mi = DaemonSets plus a ztunnel surge pod, as `namespace.yaml` already counts).
- Scenario order in the runbook: after 07, before 04: **09 → 10 → 11 → 13 → 12**.
- Page structure: purpose → preconditions → commands → expected result → evidence → talking points → reset.
- `demo-evidence` passes only with ≥ 2 pieces and ≥ 1 from an infrastructure layer (`envoy`, `argocd`, …) — unchanged framework rule.
- Execution ledger (gitignored, this machine only): `.superpowers/sdd/2026-09-28-lab-routing-scenarios/progress.md`. Every measured value, probe result and ruling goes there as it happens.
- Helper tests: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh` must end in `ALL PASS` after every helper change. Helpers do not deploy (ArgoCD syncs only `k8s/`).

## Review Focus

1. **Pinning the VirtualService to `subset: stable` before the stable pods carry `track: stable`** → the `stable` subset has no endpoints and every customers request fails. Expected: zero errors. Pinned by Task 4's two separate pushes and its "5 pods labelled" gate before the second.
2. **A scenario whose revert was forgotten** (weights, mirror, header rule or canary replicas left in place) → the next scenario's numbers are silently wrong. Expected: `demo-reset` fails and names what is left. Pinned by Task 6's routing-baseline tests.
3. **Canary pods still in their 10 s preStop when the next scenario starts** → the next window counts a dying canary. Expected: baseline not OK until no `track=canary` pod exists. Pinned by Task 6's `FAKE_CANARY_PODS` test.
4. **A patch that no longer applies** because someone edited `resilience.yaml` or the canary manifest → a live demo breaks at its first command. Expected: the helper test suite fails first. Pinned by Task 6's `git apply --check` loop.
5. **Requests between ArgoCD applying the switch and recording `deployedAt`** would be attributed to the wrong side in blue-green. Expected: segments are cut at `deployStartedAt` / `deployedAt + 15 s`, so the transition is never judged. Pinned by Task 11's segment test.

---

### Task 1: Decommission dify on vps-oracle2

**Files:**
- Delete: `vps_oracle2/compose/dify/` (tracked files; its gitignored `.env` is backed up first)
- Modify: `vps_oracle/compose/homepage/config/services.yaml` (Dify card, ~lines 137-142)
- Modify: `.github/scripts/check-compose-conventions.py:35-55` (dify exception entries)
- Modify: `README.md:36,92,124`, `vps_oracle2/README.md:3,28,35,64`, `vps_oracle2/compose/sillytavern/README.md:13`, `vps_oracle2/compose/sillytavern/docker-compose.yml:7`, `vps_oracle/compose/npm/README.md:5,96-100`

Correction to the spec: dify does **not** use vps_oracle's shared postgres/redis pools (it bundles its own `dify-db`, `dify-pgvector`, `dify-redis`); the mentions in `vps_oracle/compose/{postgres,redis}` are comments citing it as an example of a bundled store. There are no pools to drop, and those comments stay. History (`k3s/README.md`, `docs/`) and test fixtures that use `dify` merely as a namespace name also stay.

- [ ] **Step 1: Create the ledger and record the before state**

```bash
mkdir -p .superpowers/sdd/2026-09-28-lab-routing-scenarios
{ echo "# 2b execution ledger"; echo; echo "## Task 1 — dify before ($(date -u +%FT%TZ))"; } > .superpowers/sdd/2026-09-28-lab-routing-scenarios/progress.md
ssh vps-oracle2 'free -m; docker stats --no-stream --format "{{.Name}} {{.MemUsage}}" | sort' >> .superpowers/sdd/2026-09-28-lab-routing-scenarios/progress.md
```

- [ ] **Step 2: Ask the owner to confirm stopping dify and disabling NPM proxy host 24.** Wait for a yes.

- [ ] **Step 3: Stop dify, keeping its data**

```bash
docker --context oracle2 compose -f vps_oracle2/compose/dify/docker-compose.yml down   # no -v: /etc/dify/* stays on oracle2
ssh vps-oracle2 'docker ps --format "{{.Names}}" | grep -c dify || true'               # expect 0
mkdir -p ~/backups && install -m 600 vps_oracle2/compose/dify/.env ~/backups/dify-2026-09-28.env
```

- [ ] **Step 4: Disable NPM proxy host 24 (dify)** — follow the `npm-proxy-host` skill for API authentication, then `POST /api/nginx/proxy-hosts/24/disable`, then `docker exec npm nginx -t` must print `syntax is ok`. Disable, do not delete: it is reversible.

- [ ] **Step 5: Remove the stack from the repo and every current-state reference**

```bash
git rm -r -q vps_oracle2/compose/dify
rm -rf vps_oracle2/compose/dify     # only the backed-up .env is left in it
grep -rn -i dify README.md vps_oracle2 vps_oracle/compose/homepage vps_oracle/compose/npm/README.md .github/scripts/check-compose-conventions.py
```

Edit each hit:
- `README.md:36` tree comment → `node-exporter, glances, portainer-agent, sillytavern`; `:92` drop the `dify/README.md` link; `:124` → `compose/` incl. sillytavern.
- `vps_oracle2/README.md`: line 3 role sentence drops dify ("offload workloads from vps_oracle — sillytavern (compose) and, since …"); remove the `DIFY` node and its `NPM -- tailscale --> DIFY` edge from the Mermaid diagram; remove the `dify` row from the stack table; add one line under the table: `dify was decommissioned on 2026-09-28 to free memory for the lab (sub-project 2b); its data stays in /etc/dify on the host.`
- `sillytavern/README.md:13` and `sillytavern/docker-compose.yml:7`: replace "Same as dify / follows the dify model (see ../dify/README.md)" with the model stated directly: "There is no shared docker `proxy` network between the two hosts: the port is published on oracle2's tailscale IP only, and NPM on vps_oracle forwards to it over tailscale."
- `homepage/config/services.yaml`: delete the whole `- Dify:` entry (its `icon`, `href`, `description` lines).
- `npm/README.md:5`: drop "dify" from the list; in the "dify's reverse proxy (resolved 2026-09-19)" section add one sentence: `Host 24 was disabled on 2026-09-28 when dify was decommissioned.`
- `check-compose-conventions.py`: delete the three `("dify", …)` port-exception entries and the three `("dify", …, …)` inline-secret entries.

- [ ] **Step 6: Verify**

```bash
python3 .github/scripts/check-compose-conventions.py && echo CONVENTIONS-OK
grep -rn -i "compose/dify\|dify/README" --exclude-dir=.git --exclude-dir=docs . || echo NO-DANGLING-LINKS
curl -s -o /dev/null -w '%{http_code}\n' https://homepage.jerome.cloudns.asia/ # homepage still serves (200/302/401 by access list)
```

- [ ] **Step 7: Commit, one per component** (check `git status` / `git log -3` first)

```bash
git commit -m "chore(vps_oracle2): decommission the dify stack

Frees ~1.4Gi on vps-oracle2 for the lab's blue-green demo (sub-project 2b).
Stopped with compose down (volumes kept in /etc/dify); .env backed up
off-repo; NPM proxy host 24 disabled.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- vps_oracle2 README.md .github/scripts/check-compose-conventions.py
git commit -m "chore(homepage): remove the Dify card

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- vps_oracle/compose/homepage/config/services.yaml
git commit -m "docs(npm): note proxy host 24 is disabled with dify gone

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- vps_oracle/compose/npm/README.md
git pull --ff-only && git push
```

(No `k3s/` path in these commits — no push approval needed beyond Step 2.)

---

### Task 2: Give the memory back to the lab (system-reserved, quota)

**Files:**
- Modify: `k3s/install/agent-vps-oracle2/config.yaml:24-38` (kubelet `system-reserved`, comment)
- Modify: `k3s/install/agent-vps-oracle2/README.md:26`
- Modify: `k3s/apps/lab-environment/k8s/namespace.yaml:15-50` (`requests.memory`, derivation comment)
- Modify: `k3s/apps/lab-environment/README.md` ("**Quota.**" paragraph)

- [ ] **Step 1: Measure what runs outside pods now that dify is gone**

```bash
ssh vps-oracle2 'for s in system.slice user.slice init.scope; do awk -v s=$s "\$1==\"anon\"{printf \"%-12s %5d MiB\n\", s, \$2/1048576}" /sys/fs/cgroup/$s/memory.stat; done; free -m'
kubectl get node vps-oracle2 -o jsonpath='{.status.capacity.memory}{"\n"}'
```

Record both in the ledger. Compute `R = ceil((sum of the three anon values + 512) / 256) * 256` Mi — the 512Mi margin covers the kernel and page cache the anon figure omits. **Gate:** `capacity_Mi − R − 256 (kube-reserved) ≥ 10368`. If it fails, stop and report the numbers to the owner (do not shrink the green).

- [ ] **Step 2: Edit `config.yaml`** — change `"system-reserved=cpu=200m,memory=2Gi"` to `"system-reserved=cpu=200m,memory=<R>Mi"`, and rewrite its comment:

```yaml
# Reserve room for what runs here outside pods, which the scheduler cannot
# see: the docker compose stacks under vps_oracle2/compose/ (sillytavern,
# glances, portainer-agent, node-exporter) plus the OS (system-reserved:
# measured anon RSS of system.slice + user.slice + init.scope, <sum>Mi on
# 2026-09-28, + 512Mi for kernel and page cache), and k3s-agent + containerd
# (~90m, kube-reserved). dify was decommissioned on 2026-09-28 to give its
# ~1.4Gi to the lab (sub-project 2b's 5-replica green). The lab quota
# (k3s/apps/lab-environment/k8s/namespace.yaml) is sized against the
# resulting allocatable — change both files together.
```

Update `README.md:26` to match: `system-reserved 200m/<R>Mi`, the stacks list without dify, "allocatable is now 1700m / ~<allocatable>Gi", and drop the "Stopping dify would…" sentence.

- [ ] **Step 3: Ask the owner to confirm running `install.sh` (restarts k3s-agent).** Then:

```bash
k3s/install/agent-vps-oracle2/install.sh
kubectl get node vps-oracle2 -o jsonpath='{.status.allocatable.memory}{"\n"}'   # Ki; /1024 must be >= 10368
kubectl -n lab-environment get pods --no-headers | awk '$3 != "Running" && $3 != "Completed"' # expect nothing
```

- [ ] **Step 4: Raise the quota.** In `namespace.yaml` set `requests.memory: 9.5Gi` and replace the memory derivation comment with:

```yaml
    # Sized from what the lab must admit at its worst (2026-09-28, sub-project 2b):
    #   steady state (5x customers + 3x api-gateway + 2x waypoint + 2x ingress
    #     + the infra/observability pods, at their requests)             5424Mi
    #   + blue-green's green: customers-service-canary x5 at 384Mi       1920Mi
    #   + one rolling-update surge pod for each Deployment a release
    #     touches (business x4 + postgres + waypoint + generator)        1824Mi
    #   + the 64Mi db-init PreSync hook (a sync cannot start without it)   64Mi
    #                                          worst-case peak = 9232Mi -> 9.5Gi
    # Upper bound: 9728Mi + ~640Mi of DaemonSets (plus a ztunnel surge pod)
    # = 10368Mi must fit vps-oracle2's allocatable (see
    # k3s/install/agent-vps-oracle2/config.yaml), so the quota rejects a pod
    # (FailedCreate) before the node would leave it Pending.
    # 8Gi (2026-09-25..28) did not fit a 5-replica green alongside a release;
    # 6Gi before that deadlocked a release (surge filled it, the hook got
    # FailedCreate, the sync stalled 10 min).
```

Also in the CPU comment, replace "Memory holds the same way: the full 8Gi quota + DaemonSets ~640Mi fits the ~9.4Gi allocatable." with "Memory: see the requests.memory derivation above." In the lab README's **Quota** paragraph replace `requests.memory: 8Gi` → `9.5Gi` and the derivation sentence with the 5424 + 1920 + 1824 + 64 = 9232Mi arithmetic and the 10368Mi bound.

- [ ] **Step 5: Commit, ask to push, verify**

```bash
git commit -m "feat(k3s): shrink vps-oracle2's system reservation now dify is gone

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- k3s/install/agent-vps-oracle2
git commit -m "feat(lab-environment): raise the memory quota to 9.5Gi for a full-size green

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- k3s/apps/lab-environment/k8s/namespace.yaml k3s/apps/lab-environment/README.md
# ask the owner, then:
git pull --ff-only && git push
kubectl -n lab-environment describe resourcequota lab-environment-quota | grep requests.memory   # Hard 9728Mi (shown as 9.5Gi)
```

---

### Task 3: Build v2-good and v2-bad in the petclinic fork

**Repo:** `~/jerome/spring-petclinic-microservices` (fork), branch `lab-v2` off `main` (`8839b4c`).

**Files:**
- Create: `spring-petclinic-customers-service/src/main/java/org/springframework/samples/petclinic/customers/config/AppVersionHeaderFilter.java`
- Create: `spring-petclinic-customers-service/src/test/java/org/springframework/samples/petclinic/customers/config/AppVersionHeaderFilterTest.java`
- Modify: `spring-petclinic-customers-service/src/main/java/org/springframework/samples/petclinic/customers/model/Owner.java` (new getter)
- Create: `spring-petclinic-customers-service/src/test/java/org/springframework/samples/petclinic/customers/model/OwnerPrimaryPetTest.java`

**Interfaces:**
- Produces: image tags `V2_GOOD` and `V2_BAD` (12-char fork SHAs), recorded in the ledger; `X-App-Version: <12-char commit id>` on every customers-service response of these builds (absent on the current stable image); JSON field `primaryPetName` on owners.

Deviation from the spec, deliberate: v2-bad's commit **passes the fork's unit tests**. v2-good's tests cover 0 and 1 pet; v2-bad "simplifies" the getter and breaks owners with 2 pets (owners 3, 6, 10 in the live data), which only production-shaped traffic reveals — the canary's job. The bug is proven live in Task 5, not pinned by a unit test.

- [ ] **Step 1: Branch**

```bash
cd ~/jerome/spring-petclinic-microservices && git status --short && git checkout -b lab-v2 main
```

- [ ] **Step 2: Write the failing filter test**

```java
package org.springframework.samples.petclinic.customers.config;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.boot.info.GitProperties;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.util.Properties;

import static org.assertj.core.api.Assertions.assertThat;

class AppVersionHeaderFilterTest {

    private static ObjectProvider<GitProperties> provider(GitProperties git) {
        StaticListableBeanFactory factory = new StaticListableBeanFactory();
        if (git != null) {
            factory.addBean("gitProperties", git);
        }
        return factory.getBeanProvider(GitProperties.class);
    }

    private static MockHttpServletResponse run(AppVersionHeaderFilter filter) throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        filter.doFilter(new MockHttpServletRequest("GET", "/owners/1"), response, new MockFilterChain());
        return response;
    }

    @Test
    void stampsTheFirstTwelveCharactersOfTheCommitId() throws Exception {
        Properties props = new Properties();
        props.setProperty("commit.id", "0123456789abcdef0123456789abcdef01234567");

        MockHttpServletResponse response = run(new AppVersionHeaderFilter(provider(new GitProperties(props))));

        assertThat(response.getHeader("X-App-Version")).isEqualTo("0123456789ab");
    }

    @Test
    void omitsTheHeaderWhenTheBuildHasNoGitInfo() throws Exception {
        MockHttpServletResponse response = run(new AppVersionHeaderFilter(provider(null)));

        assertThat(response.getHeader("X-App-Version")).isNull();
    }
}
```

- [ ] **Step 3: Run it — expect a compilation failure** (`AppVersionHeaderFilter` does not exist)

```bash
./mvnw -q -pl spring-petclinic-customers-service test -Dtest=AppVersionHeaderFilterTest
```

- [ ] **Step 4: Implement the filter**

```java
package org.springframework.samples.petclinic.customers.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.info.GitProperties;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Stamps every response with the commit this build came from, so a caller -
 * and the mesh's access log - can tell which version answered. The value is
 * the first 12 characters of the commit id, which is also the image tag
 * lab-environment's build.sh gives the image.
 */
@Component
public class AppVersionHeaderFilter extends OncePerRequestFilter {

    static final String HEADER = "X-App-Version";

    private final String version;

    public AppVersionHeaderFilter(ObjectProvider<GitProperties> git) {
        GitProperties props = git.getIfAvailable();
        String id = props == null ? null : props.getCommitId();
        this.version = id == null ? null : id.substring(0, Math.min(12, id.length()));
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        if (version != null) {
            response.setHeader(HEADER, version);
        }
        chain.doFilter(request, response);
    }
}
```

- [ ] **Step 5: Run it — expect PASS** (same command as Step 3).

- [ ] **Step 6: Write the failing `primaryPetName` test**

```java
package org.springframework.samples.petclinic.customers.model;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class OwnerPrimaryPetTest {

    @Test
    void anOwnerWithOnePetShowsItsName() {
        Owner owner = new Owner();
        Pet pet = new Pet();
        pet.setName("Leo");
        owner.addPet(pet);

        assertThat(owner.getPrimaryPetName()).isEqualTo("Leo");
    }

    @Test
    void anOwnerWithNoPetsShowsNothing() {
        assertThat(new Owner().getPrimaryPetName()).isNull();
    }
}
```

- [ ] **Step 7: Run it — expect a compilation failure** (`getPrimaryPetName` does not exist)

```bash
./mvnw -q -pl spring-petclinic-customers-service test -Dtest=OwnerPrimaryPetTest
```

- [ ] **Step 8: Add the getter to `Owner.java`**, directly after `addPet(Pet pet)`:

```java
    /**
     * The owner's first pet by name, shown as a one-line summary on the owner card.
     */
    public String getPrimaryPetName() {
        return getPets().stream().findFirst().map(Pet::getName).orElse(null);
    }
```

- [ ] **Step 9: Run the module's whole suite — expect PASS**

```bash
./mvnw -q -pl spring-petclinic-customers-service test
```

- [ ] **Step 10: Commit v2-good**

```bash
git add -A spring-petclinic-customers-service
git commit -m "Add an X-App-Version response header and owner primaryPetName

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 11: Build and import v2-good**

```bash
cd ~/jerome/lab-environment && ./scripts/build.sh | tail -3     # prints FORK_TAG=<sha>
V2_GOOD=$(git -C ~/jerome/spring-petclinic-microservices rev-parse --short=12 HEAD)
./scripts/push-to-k3s.sh ops-lab/customers-service:$V2_GOOD
echo "V2_GOOD=$V2_GOOD" >> ~/jerome/docker-gitops/.superpowers/sdd/2026-09-28-lab-routing-scenarios/progress.md
```

- [ ] **Step 12: Commit v2-bad — the realistic "simplification"** (in the fork, replace the getter body):

```java
    /**
     * The owner's pet, shown as a one-line summary on the owner card.
     */
    public String getPrimaryPetName() {
        return getPets().stream().map(Pet::getName).reduce((first, second) -> {
            throw new IllegalStateException("owner " + id + " has more than one pet");
        }).orElse(null);
    }
```

```bash
cd ~/jerome/spring-petclinic-microservices
./mvnw -q -pl spring-petclinic-customers-service test      # expect PASS: the tests never had two pets
git commit -am "Simplify primaryPetName to a single reduce

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 13: Build and import v2-bad; restore the fork to main**

```bash
cd ~/jerome/lab-environment && ./scripts/build.sh | tail -3
V2_BAD=$(git -C ~/jerome/spring-petclinic-microservices rev-parse --short=12 HEAD)
./scripts/push-to-k3s.sh ops-lab/customers-service:$V2_BAD
echo "V2_BAD=$V2_BAD" >> ~/jerome/docker-gitops/.superpowers/sdd/2026-09-28-lab-routing-scenarios/progress.md
git -C ~/jerome/spring-petclinic-microservices checkout main
```

(`build.sh` also retags `ops-lab/*:dev` to these builds; nothing on k3s references `:dev`.)

- [ ] **Step 14: Ask the owner, then push the branch** so both SHAs are public: `git -C ~/jerome/spring-petclinic-microservices push -u origin lab-v2`.

---

### Task 4: Resident canary slot, subsets and the stable pin

**Files:**
- Modify: `k3s/apps/lab-environment/k8s/customers-service.yaml` (pod template labels)
- Create: `k3s/apps/lab-environment/k8s/customers-service-canary.yaml`
- Modify: `k3s/apps/lab-environment/k8s/resilience.yaml` (customers-service DestinationRule subsets; VirtualService `subset: stable`)
- Modify: `k3s/apps/lab-environment/k8s/waypoint.yaml` (stats inclusion)
- Modify: `k3s/istio/istiod-values.yaml` (`lab-json-accesslog` gains `app_version`)

**Interfaces:**
- Produces: subsets `stable` / `canary`; waypoint access-log field `app_version`; Prometheus series `envoy_cluster_upstream_rq_xx{job="envoy-stats", cluster_name=…, envoy_response_code_class=…}` for waypoint clusters.

The order is the point of this task (Review Focus 1): **push 1** labels the stable pods and adds the empty slot; only after all five stable pods carry `track: stable` does **push 2** add the subsets and the pin.

- [ ] **Step 1: Label stable pods** — in `customers-service.yaml`, under `spec.template.metadata.labels`, after `app: customers-service`:

```yaml
        # DestinationRule subsets select on track (stable | canary); the
        # Deployment selector stays app-only because selectors are immutable.
        track: stable
        version: v1
```

- [ ] **Step 2: Create the slot** from the stable Deployment (Deployment document only, not the Service):

```bash
cd k3s/apps/lab-environment/k8s
V2_GOOD=$(grep -oP 'V2_GOOD=\K\S+' ../../../../.superpowers/sdd/2026-09-28-lab-routing-scenarios/progress.md)
awk '/^---/{exit} {print}' customers-service.yaml \
  | sed -e 's/^  name: customers-service$/  name: customers-service-canary/' \
        -e 's/^  replicas: 5$/  replicas: 0/' \
        -e 's/^      app: customers-service$/      app: customers-service\n      track: canary/' \
        -e 's/^        track: stable$/        track: canary/' \
        -e 's/^        version: v1$/        version: v2/' \
        -e "s|image: ops-lab/customers-service:.*|image: ops-lab/customers-service:$V2_GOOD|" \
        -e '/# Bump to trigger a rolling restart/,/lab.jerome\/rollout-rev/d' \
  > customers-service-canary.yaml
```

Then prepend this header comment to `customers-service-canary.yaml`:

```yaml
# The "next version" slot for customers-service (sub-project 2b). It sits at
# replicas: 0; a routing demo scales it and points the VirtualService at the
# canary subset in one demo: commit, and git revert puts both back.
# Same ServiceAccount, env, probes, resources and preStop as the stable
# Deployment, so every AuthorizationPolicy and postgres' L4 policy already
# cover it. Pods carry app: customers-service (so the Service selects them)
# plus track: canary (so the DestinationRule can tell them apart).
```

Check: `diff <(awk '/^---/{exit} {print}' customers-service.yaml) customers-service-canary.yaml` shows only the header, name, replicas, the selector's `track: canary`, the two template labels, the image and the removed rollout-rev annotation.

- [ ] **Step 3: Commit and push 1** (ask the owner first)

```bash
cd ~/jerome/docker-gitops
git commit -m "feat(lab-environment): add an empty canary slot next to customers-service

Stable pods gain track: stable / version: v1 (one rolling restart). The
canary Deployment starts at replicas: 0; nothing routes by subset yet.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- k3s/apps/lab-environment/k8s/customers-service.yaml k3s/apps/lab-environment/k8s/customers-service-canary.yaml
git pull --ff-only && git push
T0=$(date +%s)
kubectl -n lab-environment rollout status deploy/customers-service --timeout=8m
kubectl -n lab-environment get pods -l app=customers-service,track=stable --no-headers | grep -c Running   # GATE: must print 5
kubectl -n lab-environment logs deploy/traffic-generator --since=$(( $(date +%s) - T0 + 30 ))s | awk '$2 != "200"' | wc -l   # acceptance 4: expect 0
```

Record the generator count in the ledger. Do **not** continue unless the gate printed 5.

- [ ] **Step 4: Subsets and pin** — in `resilience.yaml`, customers-service DestinationRule, after `host:`:

```yaml
  # Subsets for the canary slot (customers-service-canary.yaml). Traffic
  # policy stays at the top level, so both subsets get the same outlier
  # detection and pool.
  subsets:
    - name: stable
      labels:
        track: stable
    - name: canary
      labels:
        track: canary
```

In the customers-service VirtualService, under **both** `destination:` blocks add `subset: stable` after `host:`, and add above `http:`:

```yaml
  # Pinned to the stable subset: this pin is the routing baseline every
  # routing demo (docs/demo/09-13) returns to, and demo-reset checks it.
```

- [ ] **Step 5: Waypoint stats** — in `waypoint.yaml` `inclusionRegexps`, add `- ".*upstream_rq_[1-5]xx"` with the comment `# per-cluster response classes: the only Envoy record of mirrored (shadow) requests`.

- [ ] **Step 6: Access-log field** — in `k3s/istio/istiod-values.yaml`, `lab-json-accesslog` labels, after `upstream_service_time`:

```yaml
            # Which build answered (customers-service v2 builds set it).
            app_version: "%RESP(X-APP-VERSION)%"
```

- [ ] **Step 7: Commit and push 2** (ask the owner first)

```bash
git commit -m "feat(lab-environment): route customers-service by subset, pinned to stable

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- k3s/apps/lab-environment/k8s/resilience.yaml
git commit -m "feat(lab-environment): export waypoint response classes per cluster

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- k3s/apps/lab-environment/k8s/waypoint.yaml
git commit -m "feat(istio): log the answering build in the lab access log

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- k3s/istio/istiod-values.yaml
git pull --ff-only && git push
T1=$(date +%s)
kubectl -n lab-environment rollout status deploy/waypoint --timeout=5m
sleep 60
kubectl -n lab-environment logs deploy/traffic-generator --since=$(( $(date +%s) - T1 ))s | awk '$2 != "200"' | wc -l   # expect 0
kubectl -n lab-environment logs deploy/waypoint --tail=300 | jq -r 'select(.authority? // "" | test("customers")) | .upstream_cluster' | sort | uniq -c
```

Expected: 0 generator errors; every customers line's `upstream_cluster` now carries the stable subset — record the exact string (e.g. `inbound-vip|8081|http/stable|customers-service…;`) in the ledger; Task 6's `by_subset` is written against it. `argocd app get istio-istiod --core` and `lab-environment` both `Synced/Healthy`.

---

### Task 5: Probe the mechanisms before writing any page

Measure, do not assume. One throwaway `probe:` commit, then its revert.

**Files:** temporary edits to `k3s/apps/lab-environment/k8s/customers-service-canary.yaml` and `resilience.yaml`; ledger only.

- [ ] **Step 1: Probe commit** — canary `replicas: 1` with image `ops-lab/customers-service:$V2_BAD`; in the customers-service VirtualService insert as the first `http` entry:

```yaml
    - match:
        - headers:
            x-canary:
              exact: "true"
        - headers:
            cookie:
              regex: "^(.*; )?canary=1(;.*)?$"
      route:
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: canary
      timeout: 3s
      retries:
        attempts: 0
```

and on the GET route add:

```yaml
      mirror:
        host: customers-service.lab-environment.svc.cluster.local
        subset: canary
      mirrorPercentage:
        value: 100
```

```bash
git commit -m "probe: canary v2-bad with header route and GET mirror

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- k3s/apps/lab-environment/k8s
# ask the owner, then:
git pull --ff-only && git push
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m
```

- [ ] **Step 2: Run the probes and record every answer in the ledger**

```bash
U=http://10.0.0.95:30097
# P1 header reaches the waypoint and X-App-Version comes back through api-gateway
curl -s -o /dev/null -D- -H 'x-canary: true' $U/api/customer/owners/1 | grep -i x-app-version     # expect V2_BAD
# P2 cookie
curl -s -o /dev/null -D- -b 'canary=1' $U/api/customer/owners/1 | grep -i x-app-version          # expect V2_BAD
# P3 the bug: 2-pet owners 500 through the gateway, 1-pet owners 200
for id in 1 3 6 10; do printf '%s ' $id; curl -s -o /dev/null -w '%{http_code}\n' -H 'x-canary: true' $U/api/customer/owners/$id; done   # expect 200 500 500 500
# P4 header lost on the aggregation path
curl -s -o /dev/null -w '%{http_code}\n' -H 'x-canary: true' $U/api/gateway/owners/3              # expect 200 (stable answered)
# P5 unmarked request is served by stable and mirrored
for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{http_code}\n' $U/api/customer/owners/3; done   # expect 200 x5
sleep 30
kubectl -n lab-environment logs deploy/waypoint --tail=500 | jq -c 'select(.authority? // "" | test("customers")) | {authority, upstream_cluster, response_code, app_version}' | sort | uniq -c | sort -rn | head
curl -s -G http://10.0.0.95:30093/api/v1/query --data-urlencode 'query=envoy_cluster_upstream_rq_xx{job="envoy-stats", cluster_name=~".*canary.*"}' | jq -r '.data.result[] | "\(.metric.cluster_name) \(.metric.envoy_response_code_class) \(.value[1])"'
# P6 the canary pod's Spring metrics carry service=customers-service
curl -s -G http://10.0.0.95:30093/api/v1/query --data-urlencode 'query=sum by (service, status) (http_server_requests_seconds_count{pod=~"customers-service-canary-.*"})' | jq -r '.data.result[] | "\(.metric.service) \(.metric.status) \(.value[1])"'
# P7 ArgoCD history carries deployStartedAt / deployedAt
argocd app get lab-environment --core -o json | jq '.status.history[-1] | {revision, deployStartedAt, deployedAt}'
```

Record for each: the exact output. Decisions that follow from them:
- **Subset string** (P5 log): if the canary/stable subset is not the text after `/` in the third `|`-field, change `by_subset` in Task 6 to the measured shape.
- **Shadow in the access log** (P5 log): note whether lines with an authority ending in `-shadow` appear. Scenario 13's evidence works either way (it reads the cluster stat and excludes `-shadow` authorities from the user-facing count).
- **Stat name** (P5 Prometheus): if `cluster_name` does not match `.*http/canary.*customers-service.*`, change Task 10's selector to the measured name.
- **P3 or P1 fails** (e.g. the gateway's circuit breaker turns the 500 into a fallback, or strips the header): stop and report — scenarios 10, 11 and 13 depend on them.

- [ ] **Step 3: Revert the probe** (ask the owner)

```bash
git revert --no-edit HEAD && git pull --ff-only && git push
kubectl -n lab-environment wait --for=delete pod -l app=customers-service,track=canary --timeout=3m
```

---

### Task 6: Routing helpers and the routing baseline

**Files:**
- Modify: `k3s/apps/lab-environment/demo/lib.sh`
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`
- Create: `k3s/apps/lab-environment/demo/patches/` (empty until Tasks 7-11)

**Interfaces:**
- Produces (in `lib.sh`, consumed by Tasks 7-11):
  - `CANARY=customers-service-canary`
  - `CUST_SEL` — LogQL selector for the waypoint's customers-service lines
  - `by_subset` — stdin `"<count> <upstream_cluster>"` lines → stdout `"<count> <subset>"` per subset (`none` when no subset)
  - `count_of <key>` — stdin `"<count> <key>"` lines → the count for `key` (0 if absent)
  - `pct <part> <total>` → integer percent (0 if total is 0); `in_band <n> <lo> <hi>` → exit status
  - `subsets_between <start> <end> [extra LogQL pipeline]` → `"<count> <subset>"` lines
  - `prom_delta <selector>` → integer growth of `sum(<selector>)` between `WINDOW_START` and `SETTLED_AT` (absent = 0); call after `settle`
  - `git_image <manifest-basename>` → the first `image:` in `k8s/<name>.yaml`
  - `argocd_sync_times <sha>` → `"<deployStartedAt epoch> <deployedAt epoch>"`, empty if the sha is not in history
  - `routing_baseline` — prints each problem, non-zero if any; called by `baseline_check`
  - `REPO_ROOT` overridable with `DEMO_REPO_ROOT` (tests point it at a scratch repo)

- [ ] **Step 1: Extend the stubs and write the failing tests** — in `test-demo-helpers.sh`:

In the `curl` stub, as the first line after `echo "curl $*" >> "$FAKE_LOG"`:

```bash
if [ -n "${FAKE_CURL_HOOK:-}" ] && out=$("$FAKE_CURL_HOOK" "$*"); then printf '%s\n' "$out"; exit 0; fi
```

In the `kubectl` stub, the same hook line (with `FAKE_KUBECTL_HOOK`), then these cases **before** the existing `*" get deploy "*` case:

```bash
  *"get deploy customers-service-canary"*"spec.replicas"*) echo "${FAKE_CANARY_REPLICAS:-0}" ;;
  *"get deploy customers-service-canary"*"image"*) echo "${FAKE_CANARY_IMAGE:-$(grep -m1 -oP 'image: \K\S+' "$FAKE_LAB_K8S/customers-service-canary.yaml")}" ;;
  *"get pods -l app=customers-service,track=canary -o name"*) printf '%s' "${FAKE_CANARY_PODS:-}" ;;
  *"get virtualservice customers-service -o json"*) cat "${FAKE_VS:-$FAKE_VS_PINNED}" ;;
```

The `argocd` stub's `"history":[]` becomes `"history":${FAKE_HISTORY:-[]}`.

After the stubs:

```bash
export FAKE_LAB_K8S=$HERE/../k8s
export FAKE_VS_PINNED=$WORK/vs-pinned.json
cat > "$FAKE_VS_PINNED" <<'EOF'
{"spec":{"http":[
 {"match":[{"method":{"exact":"GET"}}],"route":[{"destination":{"host":"customers-service.lab-environment.svc.cluster.local","subset":"stable"}}]},
 {"route":[{"destination":{"host":"customers-service.lab-environment.svc.cluster.local","subset":"stable"}}]}]}}
EOF
jq '.spec.http[1].route = [{"destination":{"subset":"stable"},"weight":90},{"destination":{"subset":"canary"},"weight":10}]' "$FAKE_VS_PINNED" > "$WORK/vs-weights.json"
jq '.spec.http[0].mirror = {"subset":"canary"}' "$FAKE_VS_PINNED" > "$WORK/vs-mirror.json"
jq '.spec.http = [{"match":[{"headers":{"x-canary":{"exact":"true"}}}],"route":[{"destination":{"subset":"canary"}}]}] + .spec.http' "$FAKE_VS_PINNED" > "$WORK/vs-header.json"
jq '.spec.http[0].route[0].destination.subset = "canary"' "$FAKE_VS_PINNED" > "$WORK/vs-switched.json"
jq 'del(.spec.http[0].route[0].destination.subset)' "$FAKE_VS_PINNED" > "$WORK/vs-unpinned.json"
```

In the `demo-reset` section, after the Consul test:

```bash
# --- routing baseline (2b) ------------------------------------------------
for v in weights mirror header switched unpinned; do
  FAKE_VS=$WORK/vs-$v.json check "reset fails on a VirtualService left $v" 1 "$DEMO/demo-reset" preflight
  has "$WORK/out" "off the stable pin"
done
FAKE_CANARY_REPLICAS=1 check "reset fails while the canary is scaled up" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "customers-service-canary spec.replicas '1'"
FAKE_CANARY_PODS='pod/customers-service-canary-abc' check "reset waits for terminating canary pods" 1 "$DEMO/demo-reset" preflight
has "$WORK/out" "canary pods still present"
FAKE_CANARY_IMAGE=ops-lab/customers-service:badbadbadbad check "reset fails on a canary image off git" 1 "$DEMO/demo-reset" preflight
check "reset passes at the routing baseline" 0 "$DEMO/demo-reset" preflight

# --- routing primitives ---------------------------------------------------
. "$DEMO/lib.sh"
got=$(printf '%s\n' '7 inbound-vip|8081|http/canary|customers-service.lab-environment.svc.cluster.local;' \
                    '30 inbound-vip|8081|http/stable|customers-service.lab-environment.svc.cluster.local;' \
                    '5 inbound-vip|8081|http/stable|customers-service.lab-environment.svc.cluster.local;' \
                    '2 inbound-vip|8081|http|customers-service.lab-environment.svc.cluster.local;' | by_subset | sort -k2)
[ "$got" = "$(printf '7 canary\n2 none\n35 stable')" ] && echo "PASS by_subset" || { echo "FAIL by_subset: $got"; fails=$((fails+1)); }
[ "$(printf '7 canary\n35 stable\n' | count_of stable)" = 35 ] && [ "$(printf '7 canary\n' | count_of stable)" = 0 ] \
  && echo "PASS count_of" || { echo "FAIL count_of"; fails=$((fails+1)); }
[ "$(pct 1 6)" = 16 ] && [ "$(pct 3 0)" = 0 ] && echo "PASS pct" || { echo "FAIL pct"; fails=$((fails+1)); }
in_band 8 8 30 && in_band 30 8 30 && ! in_band 7 8 30 && ! in_band 31 8 30 && echo "PASS in_band edges" || { echo "FAIL in_band"; fails=$((fails+1)); }

# --- demo patches still apply to the tree ---------------------------------
shopt -s nullglob
for p in "$DEMO"/patches/*.patch; do
  if git -C "$HERE/../../../.." apply --check "$p" 2>"$WORK/apply.err"; then echo "PASS patch applies: $(basename "$p")"
  else echo "FAIL patch no longer applies: $(basename "$p")"; sed 's/^/    /' "$WORK/apply.err"; fails=$((fails+1)); fi
done
shopt -u nullglob
```

(`by_subset`'s fixture uses the shape assumed in the spec; if Task 5 recorded a different shape, write this fixture with the measured strings instead.)

- [ ] **Step 2: Run — expect failures:** `routing_baseline` does not exist yet, so every new "reset fails …" case exits 0 (FAIL), and `by_subset: command not found`.

```bash
bash k3s/apps/lab-environment/tests/test-demo-helpers.sh 2>&1 | grep -E "FAIL|ALL PASS|FAILED"
```

- [ ] **Step 3: Implement in `lib.sh`.** Change the `REPO_ROOT` line to:

```bash
REPO_ROOT=${DEMO_REPO_ROOT:-$(cd "$DEMO_DIR/../../../.." && pwd)}
```

Add `CANARY=customers-service-canary` after `BUSINESS=`. Append after `pg()` / `git_replicas()`:

```bash
git_image() { grep -m1 -oP 'image: \K\S+' "$LAB_K8S/$1.yaml"; }

# --- routing (2b) -----------------------------------------------------------
# The waypoint logs upstream_cluster as "inbound-vip|8081|http/<subset>|<host>;"
# (no "/<subset>" when the route names none).
CUST_SEL='{service="istio-proxy"} | json | __error__="" | authority=~"customers-service.*"'
by_subset() {
  awk '{ split($2, f, "|"); n = split(f[3], a, "/"); s = (n > 1 ? a[2] : "none"); c[s] += $1 }
       END { for (k in c) print c[k], k }'
}
count_of() { awk -v k="$1" '$2 == k { s += $1 } END { print s + 0 }'; }
pct() { if [ "$2" -gt 0 ]; then echo $(( 100 * $1 / $2 )); else echo 0; fi; }
in_band() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
subsets_between() { loki_by upstream_cluster "$CUST_SEL${3:-}" "$1" "$2" | by_subset; }
# A counter's exact growth over the window: increase() extrapolates, and a
# series born inside the window loses its first increments.
prom_delta() {
  local a b
  a=$(prom "sum($1)" "$WINDOW_START"); b=$(prom "sum($1)" "$SETTLED_AT")
  [ "$a" = none ] && a=0; [ "$b" = none ] && b=0
  awk -v a="$a" -v b="$b" 'BEGIN { printf "%d", b - a }'
}
argocd_sync_times() {
  argocd app get lab-environment --core -o json | jq -r --arg s "$1" \
    '[.status.history[] | select(.revision == $s)] | first // empty | "\(.deployStartedAt) \(.deployedAt)"' \
    | while read -r a b; do echo "$(date -u -d "$a" +%s) $(date -u -d "$b" +%s)"; done
}
# Every routing demo returns here: slot empty and on git's image, every
# VirtualService route pinned to stable - no weights, mirror or header rule.
routing_baseline() {
  local bad=0 got want pods off
  got=$(kubectl -n "$NS" get deploy "$CANARY" -o jsonpath='{.spec.replicas}')
  [ "$got" = 0 ] || { echo "$CANARY spec.replicas '$got', want 0"; bad=1; }
  pods=$(kubectl -n "$NS" get pods -l app=customers-service,track=canary -o name)
  [ -z "$pods" ] || { echo "canary pods still present: $(echo $pods)"; bad=1; }
  got=$(kubectl -n "$NS" get deploy "$CANARY" -o jsonpath='{.spec.template.spec.containers[0].image}')
  want=$(git_image "$CANARY")
  [ "$got" = "$want" ] || { echo "$CANARY image '$got', git wants $want"; bad=1; }
  off=$(kubectl -n "$NS" get virtualservice customers-service -o json | jq -r '
    [.spec.http[] | select(.mirror or .mirrors or ((.route | length) != 1)
      or .route[0].destination.subset != "stable" or any(.match[]?; .headers))] | length')
  [ "$off" = 0 ] || { echo "customers-service VirtualService has ${off:-?} route(s) off the stable pin"; bad=1; }
  return $bad
}
```

In `baseline_check`, before `return $bad`: `routing_baseline || bad=1`.

- [ ] **Step 4: Run — expect `ALL PASS`**; also `shellcheck k3s/apps/lab-environment/demo/lib.sh` shows no new warnings.

- [ ] **Step 5: Verify against the live cluster** — `k3s/apps/lab-environment/demo/demo-reset preflight` prints `baseline OK`.

- [ ] **Step 6: Commit** (helpers do not deploy; no push approval needed unless pushing with `k3s/` — ask anyway, per the global rule)

```bash
mkdir -p k3s/apps/lab-environment/demo/patches && touch k3s/apps/lab-environment/demo/patches/.gitkeep
git add k3s/apps/lab-environment/demo k3s/apps/lab-environment/tests/test-demo-helpers.sh
git commit -m "feat(lab-demo): routing baseline and subset helpers for the 2b scenarios

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

Tasks 7-11 share one page skeleton. **Sync wait** below means exactly this block (it is written out in full on every page, never referenced):

```bash
argocd app get lab-environment --core --refresh >/dev/null
end=$((SECONDS + 300)); until argocd app get lab-environment --core -o json | jq -e --arg r "$(git rev-parse HEAD)" '.status.operationState.syncResult.revision == $r and .status.operationState.phase == "Succeeded"' >/dev/null; do [ $SECONDS -lt $end ] || { echo "SYNC WAIT TIMED OUT - stop here"; break; }; sleep 5; done
```

**Version tally** below means: `| tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{v=$2} END{print (v ? v : "none (v1)")}'` appended to a `curl -s -o /dev/null -D- …`.

Each patch is produced the same way: make the stated edits under `k3s/apps/lab-environment/k8s/`, then

```bash
git diff -- k3s/apps/lab-environment/k8s > k3s/apps/lab-environment/demo/patches/<scenario>.patch
git checkout -- k3s/apps/lab-environment/k8s
git apply --check k3s/apps/lab-environment/demo/patches/<scenario>.patch && echo APPLIES
```

Scenario evidence tests use `FAKE_CURL_HOOK` / `FAKE_KUBECTL_HOOK` scripts written into `$WORK` with a **quoted** heredoc (no expansion inside the hook's source), a window file written directly, and fixture JSON passed to the hook through exported variables. The hook receives the stubbed command's arguments as one string in `$1`; it prints a response and exits 0, or exits 1 to fall through to the stub's defaults. Queries are told apart by their text and by the `time=` parameter (`prom` sends `time=<epoch>`, Loki `time=<epoch>000000000`). Add once, at the start of Task 7's test block:

```bash
cl() { printf '{"metric":{"upstream_cluster":"inbound-vip|8081|http/%s|customers-service.lab-environment.svc.cluster.local;"},"value":[0,"%s"]}' "$1" "$2"; }
res() { printf '{"data":{"result":[%s]}}' "$1"; }                 # res "<entries>"
val() { printf '{"data":{"result":[{"metric":{},"value":[0,"%s"]}]}}' "$1"; }
win() { printf 'WINDOW_START=%s\nWINDOW_END=%s\n' "$2" "$3" > "$DEMO_STATE_DIR/$1.window"; }
export -f cl res val
```

(`export -f` makes the builders callable inside hook scripts, which run as child bash processes. If Task 5 measured a different `upstream_cluster` shape, change `cl` to it.)

---

### Task 7: Scenario 09 — canary by instance ratio

**Files:**
- Create: `k3s/apps/lab-environment/demo/patches/canary-instance-ratio.patch`
- Create: `k3s/apps/lab-environment/demo/scenarios/canary-instance-ratio.sh`
- Create: `docs/demo/09-canary-instance-ratio.md`
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

**Interfaces:** Consumes `CUST_SEL`, `pct`, `in_band`, `prom_delta`, `settle`, `loki_by` (Task 6).

- [ ] **Step 1: Patch** — edits: `customers-service-canary.yaml` `replicas: 0` → `1`; `resilience.yaml` customers-service VirtualService: delete both `subset: stable` lines. Produce and check the patch as described above.

- [ ] **Step 2: Failing test**

```bash
cp "$DEMO/scenarios/canary-instance-ratio.sh" "$DEMO_SCENARIO_DIR/"
win canary-instance-ratio 1000 1300
cat > "$WORK/hook09" <<'EOF'
#!/bin/bash
c=${C09:-20}
case "$1" in
  *"track=canary"*"podIP"*) echo "10.42.1.99" ;;
  *"sum by (upstream_host)"*)
    res "{\"metric\":{\"upstream_host\":\"envoy://connect_originate/10.42.1.99:8081\"},\"value\":[0,\"$c\"]},{\"metric\":{\"upstream_host\":\"envoy://connect_originate/10.42.1.40:8081\"},\"value\":[0,\"100\"]}" ;;
  *"customers-service-canary"*"time=1000"*) val 10 ;;
  *"customers-service-canary"*"time=1320"*) val $((10 + c)) ;;
  *"time=1000"*) val 500 ;;
  *"time=1320"*) val $((500 + 100 + c)) ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook09"
FAKE_CURL_HOOK=$WORK/hook09 FAKE_KUBECTL_HOOK=$WORK/hook09 check "09 passes at 1 of 6" 0 "$DEMO/demo-evidence" canary-instance-ratio
C09=0 FAKE_CURL_HOOK=$WORK/hook09 FAKE_KUBECTL_HOOK=$WORK/hook09 check "09 fails when the canary got nothing" 1 "$DEMO/demo-evidence" canary-instance-ratio
C09=100 FAKE_CURL_HOOK=$WORK/hook09 FAKE_KUBECTL_HOOK=$WORK/hook09 check "09 fails at a 50% share" 1 "$DEMO/demo-evidence" canary-instance-ratio
```

(`prom_delta` reads at `WINDOW_START` 1000 and `SETTLED_AT` = 1300 + 20; canary-pod selectors are matched first. `C09=20` gives 20/120 = 16 % in both pieces.)

Run: `bash k3s/apps/lab-environment/tests/test-demo-helpers.sh 2>&1 | grep 09` → FAIL (`unknown scenario`).

- [ ] **Step 3: Scenario file**

```bash
# 09 — canary by instance ratio: with no subset pin the waypoint balances
# over every customers-service pod, so the canary gets 1 of 6.
evidence_canary_instance_ratio() {
  local ips hosts total canary share all c
  settle
  ips=" $(kubectl -n "$NS" get pods -l app=customers-service,track=canary -o jsonpath='{.items[*].status.podIP}') "
  hosts=$(loki_by upstream_host "$CUST_SEL" "$WINDOW_START" "$WINDOW_END")
  total=$(echo "$hosts" | awk '{ s += $1 } END { print s + 0 }')
  canary=$(echo "$hosts" | awk -v ips="$ips" '{ n = split($2, a, "/"); split(a[n], b, ":"); if (index(ips, " " b[1] " ")) s += $1 } END { print s + 0 }')
  share=$(pct "$canary" "$total")
  rec_if envoy "waypoint sent $canary of $total customers-service requests to the canary pod: ${share}% (want 8-30; 1 pod of 6)" in_band "$share" 8 30
  all=$(prom_delta 'http_server_requests_seconds_count{service="customers-service", uri!~"/actuator.*"}')
  c=$(prom_delta 'http_server_requests_seconds_count{pod=~"customers-service-canary-.*", uri!~"/actuator.*"}')
  share=$(pct "$c" "$all")
  rec_if app "canary pod's own count: $c of $all requests, ${share}% (want 8-30)" in_band "$share" 8 30
}

reset_canary_instance_ratio() {
  kubectl -n "$NS" wait --for=delete pod -l app=customers-service,track=canary --timeout=3m
}
```

Run the tests → the three 09 checks PASS.

- [ ] **Step 4: Page `docs/demo/09-canary-instance-ratio.md`**

````markdown
# 09 — Canary by instance ratio

## Purpose
Release v2 of customers-service to a share of traffic the way plain
Kubernetes does it: add one v2 pod next to five v1 pods behind the same
Service. The share is whatever the pod count makes it — 1 of 6.

## Preconditions
Preflight passed (`demo-reset preflight` → `baseline OK`; the canary slot is empty).

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/canary-instance-ratio.patch
git diff
git commit -m "demo: canary customers-service by instance ratio (5 + 1)" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m
demo-window start canary-instance-ratio
for i in $(seq 1 120); do curl -s -o /dev/null -D- http://10.0.0.95:30097/api/customer/owners/1 <Version tally, verbatim>; sleep 0.3; done | sort | uniq -c
demo-window stop canary-instance-ratio
demo-evidence canary-instance-ratio
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
```

## Expected result
Roughly 100 `none (v1)` and 20 `<v2-good sha>` — about 1 in 6. The
evidence shows the canary pod's share at 8-30 % in both the waypoint's
log and the pod's own request count.

## Evidence
- **Envoy (waypoint access log):** customers-service requests by
  `upstream_host`, the canary pod's IP picked out — its share of the total.
- **App (Spring metrics):** the canary pod's request count over the window
  as a share of all customers-service pods.

## Talking points
- No mesh feature is involved: the VirtualService's subset pin is removed,
  so the waypoint balances across all six endpoints of the Service. This is
  the canary every Kubernetes cluster can do.
- Its limit: the share is tied to replica counts. 10 % needs 9 v1 pods per
  v2 pod; 1 % needs 99. Scenario 10 decouples the two.
- v1 pods answer without `X-App-Version` — that header is the v2 build's
  change, and the waypoint logs it (`app_version`), so the version that
  answered is on the platform's record, not only the client's.

## Reset
The page's `git revert` undoes it. `demo-reset canary-instance-ratio` waits
for the canary pod to terminate and verifies the baseline, including the
stable pin.
````

Write the page with the two placeholders `<Sync wait block, verbatim>` and `<Version tally, verbatim>` **replaced by the exact text** defined above Task 7 — the page must be pasteable.

- [ ] **Step 5: Commit**

```bash
git add k3s/apps/lab-environment/demo/patches/canary-instance-ratio.patch k3s/apps/lab-environment/demo/scenarios/canary-instance-ratio.sh docs/demo/09-canary-instance-ratio.md k3s/apps/lab-environment/tests/test-demo-helpers.sh
git commit -m "feat(lab-demo): scenario 09, canary by instance ratio

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Scenario 10 — canary by weight, catch v2-bad, roll back

**Files:**
- Create: `k3s/apps/lab-environment/demo/patches/canary-weight.patch`
- Create: `k3s/apps/lab-environment/demo/scenarios/canary-weight.sh`
- Create: `docs/demo/10-canary-weight.md`
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

**Interfaces:** Consumes `subsets_between`, `count_of`, `pct`, `in_band`, `prom_delta`, `argocd_sync_times`, `REPO_ROOT` (Task 6).

- [ ] **Step 1: Patch** — edits: canary `replicas: 1` and image `ops-lab/customers-service:<V2_BAD from the ledger>`; in the customers-service VirtualService replace **each** of the two `route:` blocks with

```yaml
      route:
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: stable
          weight: 90
        - destination:
            host: customers-service.lab-environment.svc.cluster.local
            subset: canary
          weight: 10
```

- [ ] **Step 2: Failing test** (a scratch repo supplies the revert commit)

```bash
cp "$DEMO/scenarios/canary-weight.sh" "$DEMO_SCENARIO_DIR/"
export DEMO_REPO_ROOT=$WORK/repo; git init -q "$DEMO_REPO_ROOT"
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'demo: canary customers-service v2-bad at 10%'
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'Revert "demo: canary customers-service v2-bad at 10%"'
REVERT10=$(git -C "$DEMO_REPO_ROOT" rev-parse HEAD)
win canary-weight 1000 1300
export J10_ALL="$(cl canary 12),$(cl stable 100)" J10_ERR="$(cl canary 12)"
cat > "$WORK/hook10" <<'EOF'
#!/bin/bash
case "$1" in
  *'response_code=~'*) res "${E10:-$J10_ERR}" ;;
  *"sum by (upstream_cluster)"*) res "$J10_ALL" ;;
  *'customers-service-canary'*'status="500"'*"time=1320"*) val 12 ;;
  *'status="500"'*"time=1320"*) val 12 ;;
  *'status="500"'*) res "" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook10"
H10='[{"revision":"'$REVERT10'","deployStartedAt":"1970-01-01T00:22:00Z","deployedAt":"1970-01-01T00:22:10Z"}]'
FAKE_HISTORY=$H10 FAKE_CURL_HOOK=$WORK/hook10 check "10 passes: 5xx only on the canary, rollback deployed" 0 "$DEMO/demo-evidence" canary-weight
E10="$(cl canary 12),$(cl stable 3)" FAKE_HISTORY=$H10 FAKE_CURL_HOOK=$WORK/hook10 check "10 fails when stable also returned 5xx" 1 "$DEMO/demo-evidence" canary-weight
FAKE_CURL_HOOK=$WORK/hook10 check "10 fails when the rollback never deployed" 1 "$DEMO/demo-evidence" canary-weight
unset DEMO_REPO_ROOT
```

Note on the Spring piece in this fixture: stable 500 delta = (all 500 at 1320: 12) − (canary 500 at 1320: 12) = 0 — the scenario computes stable as all minus canary, so the fixture returns 12 for both.

Run → FAIL (`unknown scenario`).

- [ ] **Step 3: Scenario file**

```bash
# 10 — canary by weight on a bad build: the waypoint's log shows every 5xx
# came from the canary subset, and the rollback is a git revert.
DEMO_COMMIT_SUBJECT='demo: canary customers-service v2-bad at 10%'

evidence_canary_weight() {
  local all errs canary stable share c5 s5 revert ok a5 k5
  settle
  all=$(subsets_between "$WINDOW_START" "$WINDOW_END")
  errs=$(subsets_between "$WINDOW_START" "$WINDOW_END" ' | response_code=~"5.."')
  canary=$(echo "$all" | count_of canary); stable=$(echo "$all" | count_of stable)
  share=$(pct "$canary" $((canary + stable)))
  c5=$(echo "$errs" | count_of canary); s5=$(echo "$errs" | count_of stable)
  ok=0; [ "$s5" -eq 0 ] && [ "$c5" -gt 0 ] && in_band "$share" 3 20 && ok=1
  rec_if envoy "canary took ${share}% of customers-service requests (want 3-20); 5xx: canary $c5, stable $s5 (want > 0 and 0)" [ $ok = 1 ]
  revert=$(git -C "$REPO_ROOT" log -1 --grep="^Revert \"$DEMO_COMMIT_SUBJECT\"\$" --format=%H)
  ok=0; [ -n "$revert" ] && [ -n "$(argocd_sync_times "$revert")" ] && ok=1
  rec_if argocd "ArgoCD deployed the rollback ${revert:0:7}" [ $ok = 1 ]
  a5=$(prom_delta 'http_server_requests_seconds_count{service="customers-service", status="500"}')
  k5=$(prom_delta 'http_server_requests_seconds_count{pod=~"customers-service-canary-.*", status="500"}')
  ok=0; [ "$k5" -gt 0 ] && [ $((a5 - k5)) -eq 0 ] && ok=1
  rec_if app "Spring 500s by the pods' own count: canary $k5, stable $((a5 - k5)) (want > 0 and 0)" [ $ok = 1 ]
}

reset_canary_weight() {
  kubectl -n "$NS" wait --for=delete pod -l app=customers-service,track=canary --timeout=3m
}
```

Run → the three 10 checks PASS.

- [ ] **Step 4: Page `docs/demo/10-canary-weight.md`**

````markdown
# 10 — Canary by weight: catch a bad build, roll back

## Purpose
Send exactly 10 % of traffic to one v2 pod — a share no replica count
gives — with a build that has a real bug. Show that the platform, not the
app, pins every error on the canary, that 90 % of users never see it, and
that rolling back is one `git revert`.

## Preconditions
Preflight passed; 09 reset. The v2-bad build fails on owners with two pets
(3, 6 and 10): its "simplified" `primaryPetName` throws — and its unit
tests passed, because none had two pets.

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/canary-weight.patch
git diff
git commit -m "demo: canary customers-service v2-bad at 10%" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m
demo-window start canary-weight
for i in $(seq 1 200); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners/3; sleep 0.3; done | sort | uniq -c
demo-window stop canary-weight
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
demo-evidence canary-weight
```

## Expected result
About 180 `200` and 20 `500`. The evidence shows the canary at ~10 % of
customers-service requests, every 5xx on the canary subset and none on
stable, the rollback commit deployed, and the same split in the pods' own
500 counts.

## Evidence
- **Envoy (waypoint access log):** requests and 5xx per subset
  (`upstream_cluster`).
- **ArgoCD:** the revert's SHA in the application's deploy history.
- **App (Spring metrics):** 500s counted by the canary pod versus the five
  stable pods.

## Talking points
- The weight is independent of replicas: one pod takes 10 %, and 1 % would
  need no more pods.
- **500 is deliberately not in `retryOn`.** Retrying it would send the
  retry through the same 90/10 split — nine times in ten to stable — and
  the canary's bug would disappear from the user-facing numbers. Not
  retrying 500 is what makes a canary observable.
- Outlier detection will not save you here: with one canary pod,
  `maxEjectionPercent: 50` floors to 0, and Envoy never ejects the last
  host of a cluster. The decision to roll back is a human's (or, later,
  Argo Rollouts' analysis — sub-project 4).
- The generator's `/api/customer/owners` list also serialises owners 3, 6
  and 10, so ~10 % of its list calls fail too — the blast radius is the
  weight, not the endpoint.

## Reset
The page's revert is the rollback. `demo-reset canary-weight` waits for the
canary pod to go and verifies the baseline.
````

(Replace the two `<…, verbatim>` markers with the exact blocks, as in Task 7.)

- [ ] **Step 5: Commit** (same `git add` shape as Task 7, subject `feat(lab-demo): scenario 10, canary by weight catching a bad build`).

---

### Task 9: Scenario 11 — header / cookie gray release

**Files:**
- Create: `k3s/apps/lab-environment/demo/patches/header-canary.patch`
- Create: `k3s/apps/lab-environment/demo/scenarios/header-canary.sh`
- Create: `docs/demo/11-header-canary.md`
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

- [ ] **Step 1: Patch** — edits: canary `replicas: 1` (image stays v2-good); in the customers-service VirtualService insert as the **first** `http` entry the exact block from Task 5 Step 1 (header `x-canary: "true"` or cookie `canary=1` → subset canary, `timeout: 3s`, `retries.attempts: 0`), preceded by the comment `# Gray release: marked requests (header or cookie) go to the canary; everyone else stays on stable.`

- [ ] **Step 2: Failing test**

```bash
cp "$DEMO/scenarios/header-canary.sh" "$DEMO_SCENARIO_DIR/"
win header-canary 1000 1300
export J11_STABLE="$(cl stable 90)"
cat > "$WORK/hook11" <<'EOF'
#!/bin/bash
case "$1" in
  *"sum by (upstream_cluster)"*) res "$(cl canary "${C11:-40}"),$J11_STABLE" ;;
  *"customers-service-canary"*"time=1000"*) val 3 ;;
  *"customers-service-canary"*"time=1320"*) val 43 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook11"
FAKE_CURL_HOOK=$WORK/hook11 check "11 passes: exactly the 40 marked requests hit the canary" 0 "$DEMO/demo-evidence" header-canary
C11=41 FAKE_CURL_HOOK=$WORK/hook11 check "11 fails when an unmarked request reached the canary" 1 "$DEMO/demo-evidence" header-canary
```

Run → FAIL.

- [ ] **Step 3: Scenario file**

```bash
# 11 — header / cookie gray release: only marked requests reach the canary.
MARKED=40   # the page sends 20 with the x-canary header and 20 with the cookie

evidence_header_canary() {
  local all canary stable c
  settle
  all=$(subsets_between "$WINDOW_START" "$WINDOW_END")
  canary=$(echo "$all" | count_of canary); stable=$(echo "$all" | count_of stable)
  rec_if envoy "waypoint routed $canary requests to the canary (want exactly $MARKED, the marked ones) and $stable to stable (want > 0)" \
    [ "$canary" -eq "$MARKED" -a "$stable" -gt 0 ]
  c=$(prom_delta 'http_server_requests_seconds_count{pod=~"customers-service-canary-.*", uri!~"/actuator.*"}')
  rec_if app "the canary pod counted $c requests itself (want $MARKED)" [ "$c" -eq "$MARKED" ]
}

reset_header_canary() {
  kubectl -n "$NS" wait --for=delete pod -l app=customers-service,track=canary --timeout=3m
}
```

Run → PASS.

- [ ] **Step 4: Page `docs/demo/11-header-canary.md`**

````markdown
# 11 — Header / cookie gray release (A/B)

## Purpose
Send only chosen users to v2 — testers with a header, a cohort with a
cookie — while everyone else stays on v1, and show where a routing header
stops working.

## Preconditions
Preflight passed; 10 reset.

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/header-canary.patch
git diff
git commit -m "demo: route marked requests to the customers-service canary" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m
U=http://10.0.0.95:30097
demo-window start header-canary
echo "header:";   for i in $(seq 1 20); do curl -s -o /dev/null -D- -H 'x-canary: true' $U/api/customer/owners/1 <Version tally, verbatim>; done | sort | uniq -c
echo "cookie:";   for i in $(seq 1 20); do curl -s -o /dev/null -D- -b 'canary=1' $U/api/customer/owners/1 <Version tally, verbatim>; done | sort | uniq -c
echo "unmarked:"; for i in $(seq 1 20); do curl -s -o /dev/null -D- $U/api/customer/owners/1 <Version tally, verbatim>; done | sort | uniq -c
echo "aggregation path, with header:"; for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code}\n' -H 'x-canary: true' $U/api/gateway/owners/1; done | sort | uniq -c
demo-window stop header-canary
demo-evidence header-canary
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
```

## Expected result
header: `20 <v2-good sha>`; cookie: `20 <v2-good sha>`; unmarked:
`20 none (v1)`; aggregation path: `10 200`. The evidence shows exactly 40
requests on the canary subset and 40 counted by the canary pod.

## Evidence
- **Envoy (waypoint access log):** requests per subset — the canary count
  equals the number of marked requests exactly (the traffic generator
  sends neither mark, so nothing else can reach the canary).
- **App (Spring metrics):** the canary pod's own request count.

## Talking points
- The VirtualService rule order is the policy: the marked-request rule sits
  first; everything else falls through to the stable pin.
- **Where it breaks:** `/api/customer/**` is proxied by the gateway as-is,
  headers included, so the mark reaches the waypoint in front of
  customers-service. `/api/gateway/owners/{id}` makes *new* requests from
  the gateway's own code and drops it — those calls land on stable. A
  routing header only works across hops if every app propagates it; that
  is sub-project 3's lane work (Micrometer baggage).
- Cookie-based routing is how an A/B cohort sticks to one variant across
  requests; the header is how a tester opts in.

## Reset
The page's revert undoes it. `demo-reset header-canary` waits for the
canary pod to go and verifies the baseline.
````

Replace the `<…, verbatim>` markers.

- [ ] **Step 5: Commit** (subject `feat(lab-demo): scenario 11, header and cookie gray release`).

---

### Task 10: Scenario 13 — traffic mirroring

**Files:**
- Create: `k3s/apps/lab-environment/demo/patches/mirror.patch`
- Create: `k3s/apps/lab-environment/demo/scenarios/mirror.sh`
- Create: `docs/demo/13-mirror.md`
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

- [ ] **Step 1: Patch** — edits: canary `replicas: 1`, image `ops-lab/customers-service:<V2_BAD>`; on the customers-service VirtualService's **GET** route only, after `timeout: 3s`… add the `mirror` / `mirrorPercentage: {value: 100}` block from Task 5 Step 1, with the comment `# Shadow every GET to the canary; its responses are discarded. GET only: both versions share one database, so a mirrored POST would write twice.`

- [ ] **Step 2: Failing test**

```bash
cp "$DEMO/scenarios/mirror.sh" "$DEMO_SCENARIO_DIR/"
win mirror 1000 1300
export J13_STABLE="$(cl stable 150)"
cat > "$WORK/hook13" <<'EOF'
#!/bin/bash
case "$1" in
  *"envoy_cluster_upstream_rq_xx"*"time=1000"*) val 0 ;;
  *"envoy_cluster_upstream_rq_xx"*"time=1320"*) val 25 ;;
  *"sum by (upstream_cluster)"*) res "$J13_STABLE" ;;
  *"traffic-generator"*'!~'*) val "${G13:-0}" ;;
  *"traffic-generator"*) val 300 ;;
  *'status="500"'*"time=1000"*) res "" ;;
  *'status="500"'*"time=1320"*) val 25 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook13"
FAKE_CURL_HOOK=$WORK/hook13 check "13 passes: shadow failed, users all 200" 0 "$DEMO/demo-evidence" mirror
G13=2 FAKE_CURL_HOOK=$WORK/hook13 check "13 fails when a user saw an error" 1 "$DEMO/demo-evidence" mirror
```

Run → FAIL.

- [ ] **Step 3: Scenario file**

```bash
# 13 — mirroring a bad build: the shadow fails on every mirrored call to a
# 2-pet owner, and no user sees it.
evidence_mirror() {
  local shadow5 all canary stable k5 gtotal gbad
  settle
  shadow5=$(prom_delta 'envoy_cluster_upstream_rq_xx{job="envoy-stats", cluster_name=~".*http/canary.*customers-service.*", envoy_response_code_class="5"}')
  # User-facing lines only: if this Envoy also logs the shadow copies, they
  # carry an authority ending in -shadow.
  all=$(subsets_between "$WINDOW_START" "$WINDOW_END" ' | authority!~".*-shadow"')
  canary=$(echo "$all" | count_of canary); stable=$(echo "$all" | count_of stable)
  rec_if envoy "waypoint canary cluster answered $shadow5 mirrored requests with 5xx (want > 0); users were served by stable $stable, canary $canary (want > 0 and 0)" \
    [ "$shadow5" -gt 0 -a "$canary" -eq 0 -a "$stable" -gt 0 ]
  k5=$(prom_delta 'http_server_requests_seconds_count{pod=~"customers-service-canary-.*", status="500"}')
  gtotal=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  gbad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  rec_if app "canary pod's own 500s: $k5 (want > 0); generator: $gbad non-200 of $gtotal (want 0 of > 0)" \
    [ "$k5" -gt 0 -a "$gbad" -eq 0 -a "$gtotal" -gt 0 ]
}

reset_mirror() {
  kubectl -n "$NS" wait --for=delete pod -l app=customers-service,track=canary --timeout=3m
}
```

(If Task 5 recorded a different `cluster_name` shape, use it in the `shadow5` selector and in the fixture.) Run → PASS.

- [ ] **Step 4: Page `docs/demo/13-mirror.md`**

````markdown
# 13 — Traffic mirroring

## Purpose
Test v2 against real production traffic without any user depending on its
answer: every GET is copied to the canary, its response thrown away. The
same bad build as 10 — and this time no user gets a 500.

## Preconditions
Preflight passed; 11 reset.

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/mirror.patch
git diff
git commit -m "demo: mirror customers-service GETs to v2-bad" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=6m
demo-window start mirror
for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.95:30097/api/customer/owners/3; sleep 0.5; done | sort | uniq -c
demo-window stop mirror
demo-evidence mirror
kubectl -n lab-environment logs deploy/customers-service-canary --since=5m | grep -m3 'more than one pet'
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
```

## Expected result
`60 200`. The evidence shows the canary cluster returning 5xx to the
mirrored copies, no user request routed to the canary, the canary pod's
own 500s, and the generator all-200. The canary's log shows the
`IllegalStateException: owner 3 has more than one pet`.

## Evidence
- **Envoy (waypoint cluster stats):** 5xx responses on the canary subset's
  cluster (`envoy_cluster_upstream_rq_xx`); the access log shows every user
  request served by stable.
- **App:** the canary pod's own 500 count; the generator's log all 200.

## Talking points
- Mirroring is fire-and-forget: Envoy does not wait for the shadow and
  discards its response, so v2's latency and errors cost the user nothing.
- **GET only, on purpose:** both versions share one database. Mirroring a
  POST would create every owner twice. Mirroring writes needs a separate
  data store — the reason teams often mirror only reads.
- The shadow gets 100 % of read load: size the canary for it.
- Compare 10: the same bug cost ~10 % of users there, zero here. The price
  is that a mirror cannot tell you how users *react* to v2 — only whether
  it breaks.

## Reset
The page's revert undoes it. `demo-reset mirror` waits for the canary pod to
go and verifies the baseline.
````

Replace the `<…, verbatim>` markers.

- [ ] **Step 5: Commit** (subject `feat(lab-demo): scenario 13, mirroring a bad build`).

---

### Task 11: Scenario 12 — blue-green switch

**Files:**
- Create: `k3s/apps/lab-environment/demo/patches/blue-green-up.patch`, `k3s/apps/lab-environment/demo/patches/blue-green-switch.patch`
- Create: `k3s/apps/lab-environment/demo/scenarios/blue-green.sh`
- Create: `docs/demo/12-blue-green.md`
- Modify: `k3s/apps/lab-environment/tests/test-demo-helpers.sh`

- [ ] **Step 1: Patches** — `blue-green-up`: canary `replicas: 5` (image v2-good). `blue-green-switch`: in the customers-service VirtualService change both `subset: stable` to `subset: canary`. Produce each separately; check both apply to the baseline tree.

- [ ] **Step 2: Failing test** — window 1000-2000; switch deploy started 1200, finished 1210; rollback started 1600, finished 1610. Segments are queried at `time=` 1200 (before), 1600 (green), 2000 (after).

```bash
cp "$DEMO/scenarios/blue-green.sh" "$DEMO_SCENARIO_DIR/"
export DEMO_REPO_ROOT=$WORK/repo12; git init -q "$DEMO_REPO_ROOT"
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'demo: switch customers-service to green'; SW=$(git -C "$DEMO_REPO_ROOT" rev-parse HEAD)
git -C "$DEMO_REPO_ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'Revert "demo: switch customers-service to green"'; BK=$(git -C "$DEMO_REPO_ROOT" rev-parse HEAD)
win blue-green 1000 2000
H12='[{"revision":"'$SW'","deployStartedAt":"1970-01-01T00:20:00Z","deployedAt":"1970-01-01T00:20:10Z"},{"revision":"'$BK'","deployStartedAt":"1970-01-01T00:26:40Z","deployedAt":"1970-01-01T00:26:50Z"}]'
export J12_STABLE="$(cl stable 200)" J12_GREEN="$(cl canary 350)" J12_BACK="$(cl stable 350)" J12_LEAK="$(cl canary 3)"
cat > "$WORK/hook12" <<'EOF'
#!/bin/bash
case "$1" in
  *"sum by (upstream_cluster)"*"time=1200000000000"*) res "$J12_STABLE${A12:+,$J12_LEAK}" ;;
  *"sum by (upstream_cluster)"*"time=1600000000000"*) res "$J12_GREEN" ;;
  *"sum by (upstream_cluster)"*"time=2000000000000"*) res "$J12_BACK" ;;
  *"traffic-generator"*'!~'*) val 0 ;;
  *"traffic-generator"*) val 1000 ;;
  *"quantile_over_time"*) val 412 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/hook12"
: > "$FAKE_LOG"
FAKE_HISTORY=$H12 FAKE_CURL_HOOK=$WORK/hook12 check "12 passes: blue, then green, then blue" 0 "$DEMO/demo-evidence" blue-green
has "$FAKE_LOG" "[200s]"
grep -q '\[375s\].*time=1600000000000' "$FAKE_LOG" && echo "PASS 12 green segment starts at deployedAt + 15" || { echo "FAIL 12 green segment range"; fails=$((fails+1)); }
A12=1 FAKE_HISTORY=$H12 FAKE_CURL_HOOK=$WORK/hook12 check "12 fails on green traffic before the switch" 1 "$DEMO/demo-evidence" blue-green
FAKE_CURL_HOOK=$WORK/hook12 check "12 fails without the switch in ArgoCD history" 1 "$DEMO/demo-evidence" blue-green
unset DEMO_REPO_ROOT
```

(Ranges: before 1000 → 1200 = 200 s; green 1210 + 15 = 1225 → 1600 = 375 s; after 1610 + 15 = 1625 → 2000 = 375 s. The two range assertions pin Review Focus 5: the in-flight seconds around each sync are never judged.)

Run → FAIL.

- [ ] **Step 3: Scenario file**

```bash
# 12 — blue-green: a full-size green (the canary slot at 5 replicas) takes
# 100 % at the switch's sync and gives it back at the rollback's.
SWITCH_SUBJECT='demo: switch customers-service to green'
TRANSITION=15   # s after a sync finishes before the waypoint must be on the new route

evidence_blue_green() {
  local sw back t a b c ok s1 e1 s2 e2 gtotal gbad
  settle
  sw=$(git -C "$REPO_ROOT" log -1 --grep="^$SWITCH_SUBJECT\$" --format=%H)
  back=$(git -C "$REPO_ROOT" log -1 --grep="^Revert \"$SWITCH_SUBJECT\"\$" --format=%H)
  t=$(argocd_sync_times "$sw"); s1=${t% *}; e1=${t#* }
  t=$(argocd_sync_times "$back"); s2=${t% *}; e2=${t#* }
  ok=0; [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" -gt "$WINDOW_START" ] && [ "$s2" -gt $((e1 + TRANSITION)) ] \
    && [ "$WINDOW_END" -gt $((e2 + TRANSITION)) ] && ok=1
  rec_if argocd "ArgoCD deployed the switch ${sw:0:7} and its rollback ${back:0:7} inside the window" [ $ok = 1 ]
  [ $ok = 1 ] || return 0
  # Requests between a sync's start and end + TRANSITION are in flight
  # between routes and are not judged.
  a=$(subsets_between "$WINDOW_START" "$s1")
  b=$(subsets_between $((e1 + TRANSITION)) "$s2")
  c=$(subsets_between $((e2 + TRANSITION)) "$WINDOW_END")
  echo "      before: $(echo $a) | green: $(echo $b) | after: $(echo $c)"
  ok=0
  [ "$(echo "$a" | count_of canary)" -eq 0 ] && [ "$(echo "$a" | count_of stable)" -gt 0 ] &&
  [ "$(echo "$b" | count_of stable)" -eq 0 ] && [ "$(echo "$b" | count_of canary)" -gt 0 ] &&
  [ "$(echo "$c" | count_of canary)" -eq 0 ] && [ "$(echo "$c" | count_of stable)" -gt 0 ] && ok=1
  rec_if envoy "waypoint subsets: all blue before the switch, all green after it, all blue after the rollback" [ $ok = 1 ]
  gtotal=$(loki_count '{service="traffic-generator"}' "$WINDOW_START" "$WINDOW_END")
  gbad=$(loki_count '{service="traffic-generator"} !~ " 200 "' "$WINDOW_START" "$WINDOW_END")
  rec_if app "generator over the whole window: $gbad non-200 of $gtotal (want 0 of > 0)" [ "$gbad" -eq 0 -a "$gtotal" -gt 0 ]
  note "green P99 over its first 60 s: $(loki_instant "max(quantile_over_time(0.99, $CUST_SEL | unwrap duration_ms [60s]))" $((e1 + 60)) | jq -r '.data.result[0].value[1] // "n/a"') ms (cold JVMs)"
}

reset_blue_green() {
  kubectl -n "$NS" wait --for=delete pod -l app=customers-service,track=canary --timeout=4m
}
```

Run → PASS.

- [ ] **Step 4: Page `docs/demo/12-blue-green.md`**

````markdown
# 12 — Blue-green switch

## Purpose
Bring up a complete second copy of customers-service (green, v2, five pods
like blue), move all traffic to it in one step, and move it back in one
step — with no user-visible error either way.

## Preconditions
Preflight passed; 13 reset. The lab memory quota (9.5Gi) was sized for a
five-pod green alongside a full release; dify was decommissioned to make
room.

## Commands
```bash
git pull --ff-only
git apply k3s/apps/lab-environment/demo/patches/blue-green-up.patch
git diff
git commit -m "demo: bring up green customers-service (5 x v2)" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
kubectl -n lab-environment rollout status deploy/customers-service-canary --timeout=8m
kubectl -n lab-environment get pods -l app=customers-service -L track
demo-window start blue-green
sleep 30
git apply k3s/apps/lab-environment/demo/patches/blue-green-switch.patch
git diff
git commit -m "demo: switch customers-service to green" -- k3s/apps/lab-environment/k8s
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
for i in $(seq 1 20); do curl -s -o /dev/null -D- http://10.0.0.95:30097/api/customer/owners/1 <Version tally, verbatim>; sleep 1; done | sort | uniq -c
sleep 30
git revert --no-edit HEAD
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
sleep 45
demo-window stop blue-green
demo-evidence blue-green
git revert --no-edit HEAD~2
git push || echo "PUSH FAILED - stop here"
<Sync wait block, verbatim>
```

(`HEAD~2` is the "bring up green" commit: HEAD is the switch's revert, HEAD~1 the switch.)

## Expected result
After the switch every response carries the v2-good SHA. The evidence
shows all traffic on blue before the switch, all on green after it, all on
blue after the rollback, both syncs deployed, and zero generator errors
over the whole window; green's P99 in its first minute is noted.

## Evidence
- **Envoy (waypoint access log):** subset per request in three segments
  cut at the two syncs (the few seconds while a route change propagates are
  excluded).
- **ArgoCD:** the switch and its revert in the deploy history, with their
  start/end times — the segment boundaries.
- **App:** the traffic generator all 200 across both switches.

## Talking points
- The switch is one field in git (`subset: stable` → `canary`), atomic at
  the waypoint: no mixed period like a rolling update, and the rollback is
  the same size.
- **Cost:** double capacity for the duration — five more JVMs, 1920Mi of
  requests. On this node that meant decommissioning dify and resizing the
  quota (derivation in `namespace.yaml`).
- Green starts cold: its first minute's P99 is higher (JIT). Warm green
  before switching — this page waits 30 s; production would replay traffic
  or mirror to it (scenario 13) first.
- Both colours share one database schema, so v2 cannot ship an
  incompatible migration. Blue-green switches code, not data — the schema
  must be compatible with both (expand/contract).

## Reset
The page's last revert scales green back to 0. `demo-reset blue-green`
waits for the five green pods to terminate and verifies the baseline.
````

Replace the `<…, verbatim>` markers.

- [ ] **Step 5: Commit** (subject `feat(lab-demo): scenario 12, blue-green switch`).

---

### Task 12: Runbook index, docs, rehearsal and results

**Files:**
- Modify: `docs/demo/README.md` (order table)
- Modify: `k3s/apps/lab-environment/README.md` (new "Canary slot" paragraph)
- Create: `docs/demo/evidence/{canary-instance-ratio,canary-weight,header-canary,mirror,blue-green}.txt`
- Modify: `docs/superpowers/specs/2026-09-28-lab-routing-scenarios-design.md` (Implementation results)
- Modify: `docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md` (2b row; memory-ceiling note)

- [ ] **Step 1: Order table** — in `docs/demo/README.md`, after the `07` row insert:

```markdown
| 09 | [Canary by instance ratio](09-canary-instance-ratio.md) | Routing before resilience; 09-13 each leave the canary slot empty |
| 10 | [Canary by weight: catch a bad build](10-canary-weight.md) | |
| 11 | [Header / cookie gray release](11-header-canary.md) | |
| 13 | [Traffic mirroring](13-mirror.md) | Same bad build as 10, zero user impact |
| 12 | [Blue-green switch](12-blue-green.md) | Five extra JVMs — heaviest routing step |
```

- [ ] **Step 2: Lab README** — after the "**Replicas and rollout.**" paragraph add:

```markdown
**Canary slot.** `customers-service-canary` sits at `replicas: 0` next to
`customers-service`, on a v2 build of the fork's `lab-v2` branch. Its pods
carry `app: customers-service` (so the Service selects them) and
`track: canary`; stable pods carry `track: stable`. The customers-service
DestinationRule defines `stable` / `canary` subsets on `track`, and the
VirtualService pins every route to `stable` — the baseline the routing demos
(docs/demo/09-13) return to and `demo-reset` checks. A routing demo is one
patch from `demo/patches/`, committed and later reverted. Adding the pin
required two pushes: the labels first, the pin only once all five stable
pods carried `track: stable` — pinned to an empty subset, every
customers-service request would fail.
```

- [ ] **Step 3: Rehearsal** — ask the owner to approve the rehearsal's pushes as one batch. Then, from the repo root: `demo-reset preflight` → `baseline OK`; run pages **09, 10, 11, 13, 12 in that order**, pasting each page's Commands verbatim, with `DEMO_SAVE_DIR=docs/demo/evidence` exported so every passing `demo-evidence` saves its output; after each page `demo-reset <scenario>` → `baseline OK`. Record in the ledger: every page's printed counts, each evidence verdict, the canary share and 5xx counts in 10, the P99 note in 12, and `kubectl -n lab-environment describe resourcequota` taken while green is at 5/5.

- [ ] **Step 4: Acceptance 3 check** — during scenario 12 while green is 5/5 (right after its `rollout status`), and again after the rehearsal:

```bash
kubectl -n lab-environment describe resourcequota lab-environment-quota | grep requests.memory     # record Used/Hard
kubectl -n lab-environment get pods --field-selector=status.phase=Pending --no-headers | wc -l       # expect 0
kubectl -n lab-environment get events --field-selector reason=FailedCreate -o json \
  | jq --arg s "<rehearsal start, UTC ISO from the ledger>" '[.items[] | select((.lastTimestamp // .eventTime) >= $s)] | length'   # expect 0
```

Also in the lab Grafana (NodePort 30094) → Alerting → folder *Lab Capacity*: the state history of `Lab Pod Pending` and `Lab Quota Near Limit` shows no firing during the rehearsal.

- [ ] **Step 5: Results** — append to the 2b spec an `## Implementation results (<date>)` section in the 2a spec's shape: an acceptance table (criteria 1-5 with PASS/FAIL and evidence), a **Measured** list (canary shares, 5xx counts, blue-green switch/rollback times, green P99, quota usage at green 5/5, system-reserved and allocatable values, generator errors during Task 4's rollout), **Deviations from the plan** (at least: v2-bad passes the fork's unit tests on purpose; dify had no shared pools; anything Task 5's probes changed), and **Open findings**. Update the roadmap row 2b to `**Done <date>**` with links (spec, plan, pages), and rewrite the "Memory is now the next ceiling for 2b" sentence to: `Resolved in 2b (<date>): dify decommissioned, system-reserved <R>Mi, lab quota 9.5Gi — sized for a 5-replica green plus a full release.`

- [ ] **Step 6: Final checks**

```bash
bash k3s/apps/lab-environment/tests/test-demo-helpers.sh | tail -1   # ALL PASS
python3 .github/scripts/check-compose-conventions.py
demo-reset preflight                                                   # baseline OK
git status --short                                                     # only intended files
```

- [ ] **Step 7: Commit and push** (ask the owner)

```bash
git add docs/demo k3s/apps/lab-environment/README.md docs/superpowers/specs/2026-09-28-lab-routing-scenarios-design.md docs/superpowers/specs/2026-09-25-lab-sdlc-demo-roadmap.md
git commit -m "docs(demo): record the 2b rehearsal and mark the sub-project done

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git pull --ff-only && git push
```

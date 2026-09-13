# provider-switch Generalization — switchboard Design Doc

- Date: 2026-08-13
- Status: design confirmed, pending implementation
- Host involved: vps_oracle
- Predecessor doc: [`2026-08-09-claude-provider-group-switch-design.md`](2026-08-09-claude-provider-group-switch-design.md) (the original design of provider-switch, the subject of this doc's rework)

---

## 1. Background and motivation

The existing `vps_oracle/compose/provider-switch/` does one thing: switch the Claude provider (Official ↔ CCR) for the jerome/bridget groups. The types and count of switches are hardcoded in the `GROUPS` dict in `status.py` and in `toggle_group()` in `app.py` — adding a new switch means changing code and rebuilding the image.

The user wants to turn this container into a **generic, config-driven switch framework**: a config file declares which switches exist, and what logic each switch's "on"/"off" invokes is also decided by config. Adding/removing any switch requires no change to the engine itself — just writing config + attaching logic scripts. That way any future "needs a switch" scenario (e.g. debug logging for some service) can reuse the same UI/engine instead of spinning up a fresh dedicated little service each time.

### 1.1 Requirements list

| # | Requirement |
|---|---|
| R1 | Adding/removing switches done purely via config + scripts, no engine-code changes |
| R2 | What logic executes on "on"/"off" for each switch is entirely up to the author — scripts may call any code |
| R3 | Keep provider-switch's principle: the UI checks real state live on every open, no caching, no assumptions |
| R4 | The existing jerome/bridget CCR switching keeps working in place, behavior unchanged |
| R5 | The service is renamed `switchboard`; related docs/references updated accordingly |

---

## 2. Trade-offs

**Logic definition**: shell scripts vs Python handler plugins vs HTTP webhook. Chose shell scripts — scripts can call any language and any code, the most extensible, and it fits naturally with the existing `toggle_group()` "write a file" implementation; no need to pre-register a handler class in the engine for each new logic type.

**Scope of rework**: rework provider-switch in place (renamed switchboard) vs build a new standalone service. Chose in-place rework — avoids maintaining two switch UIs, two NPM reverse-proxy records, two homepage cards.

**Script granularity**: three independent scripts per switch (`status.sh`/`on.sh`/`off.sh`) vs one script + subcommand args. Chose three independent files — clear responsibilities, no risk of an argument-parsing bug making `on` run `off`'s logic.

---

## 3. Final design

### 3.1 Directory layout

```
vps_oracle/compose/switchboard/
  app.py                 ← generic engine: HTTP handler, rendering, /toggle dispatch
  config.py              ← generic engine: load switches.ini, run status/on/off, lock, timeout
  switches.ini            ← switch list (committed to git, no secrets)
  switches/
    jerome-ccr/
      status.sh
      on.sh
      off.sh
    bridget-ccr/
      status.sh
      on.sh
      off.sh
  Dockerfile
  docker-compose.yml
  README.md
  test_app.py
  test_config.py
```

Adding a switch = create a `switches/<id>/` directory + 3 scripts + add a section to `switches.ini` + `docker compose up -d --build` (the same deployment approach as any other change in this repo, no hot-reload mechanism needed).

### 3.2 `switches.ini` structure

Use the stdlib's `configparser` (INI) for the config format, not YAML — this repo's existing convention for small services is "pure stdlib, no framework" (see `provider-switch/README.md`, and the `Dockerfile` has no `pip install` step); pulling in a third-party dep like PyYAML would break that convention. A flat section+key=value structure like `switches.ini` doesn't need YAML's expressiveness anyway — INI is simpler and natively supports comments.

```ini
[jerome-ccr]
group = Provider          ; optional, used for UI grouping
label = jerome
on_label = CCR             ; status text + "Switch to X" button text both come from here
off_label = Official

[bridget-ccr]
group = Provider
label = bridget
on_label = CCR
off_label = Official
```

The section name matches the `switches/<id>/` directory name (i.e. the switch id). When `group` is absent, that switch isn't grouped and displays on its own line.

### 3.3 Script contract per switch

| Script | When invoked | Contract |
|---|---|---|
| `status.sh` | every `GET /` (status must be live-checked, see R3) | exit 0 = **on**; exit 2 = **error** (an anomaly the script itself discovered, e.g. a permissions error reading a config file — grouped under ERROR like timeout/script-missing, not treated as off); any other non-zero = **off**. The first stdout line (optional) is shown as detail text on that row — used to carry the formerly-hardcoded endpoint/health info; generic switches may not have such info, so it can be left empty. |
| `on.sh` | `POST /toggle`, when current state is off | exit 0 = success, non-zero = failure. |
| `off.sh` | `POST /toggle`, when current state is on | same as above. |

Failure handling:
- `on.sh`/`off.sh` failure (non-zero exit) → don't silently bounce back to `/`; instead show an error page with truncated stderr.
- `status.sh` failure/timeout → that row shows **ERROR**, not treated as off (a broken probe masquerading as "the safe off state" is more dangerous than a clear error), and the row's toggle button is hidden (no action allowed when state is unknown).

### 3.4 Engine behavior

- **Concurrent probing**: one `GET /` runs all switches' `status.sh` concurrently via a thread pool (`max_workers=8`); page load time is bounded by the slowest single probe, not the sum — this only pays off once the switch count grows; with two switches it isn't slower either.
- **Lock**: the engine (not the script author) takes an `flock` on the switch id before calling `on.sh`/`off.sh`, serializing concurrent `/toggle` requests. The lock file lives at `switches/<id>/.lock`, the same idea as `status.py` originally putting its lock at `env_path + ".lock"` — the lock sits next to the resource it protects.
- **Timeout**: `status.sh` 5 seconds, `on.sh`/`off.sh` 15 seconds. Timeout is treated as failure (see 3.3).
- All scripts inherit the container's own env vars (same as `CCR_TOKEN` currently flowing through `docker-compose.yml`'s `environment`); secrets don't go into `switches.ini`.

### 3.5 UI

`render_page()`'s table becomes: `Group(if any)| Name | State | Detail | Action`.

- State/Action button text comes from the switch's own `on_label`/`off_label`, no longer the global hardcoded `PROVIDER_LABELS`.
- The Detail column shows the first line of `status.sh` output, empty if none (the old endpoint/health columns are replaced by this single generic field).
- ERROR state: red `ERROR` text, no toggle button rendered.

### 3.6 Migrating the jerome/bridget CCR switches

The existing `toggle_group()` two-way branch based on current state is split into two switches of 3 scripts each:

- `switches/jerome-ccr/status.sh`: read `jerome.env` to check whether `ANTHROPIC_BASE_URL` exists (corresponds to the current `read_config`), then probe CCR connectivity (corresponds to `check_connectivity`), assembling the result into detail text (e.g. `"CCR http://127.0.0.1:3456 — reachable"` / `"... — UNREACHABLE"`).
- `switches/jerome-ccr/on.sh`: write the two CCR `export` lines (tmp file + `rename` atomic replace, same as now).
- `switches/jerome-ccr/off.sh`: clear the file (write a comment line).
- `bridget-ccr`'s three scripts have the same structure, with paths changed to `bridget.env`.

There's some duplication between the two script sets (both "read env file + probe the same CCR + atomic write"), but the payoff is each switch being self-contained, mutually independent, and modifiable alone without worrying about the other — appropriate for the current scale of two near-identical use cases, no premature shared library.

### 3.7 Rename (`provider-switch` → `switchboard`) impact scope

Code/config side (done together in this implementation):

| File | Change |
|---|---|
| Directory `vps_oracle/compose/provider-switch/` | renamed wholesale to `switchboard/` |
| `docker-compose.yml` | `container_name`, `image` changed to `switchboard` |
| Root `README.md` | the service name on the `ccr` / `provider-switch` line updated |
| `vps_oracle/compose/ccr/README.md` | currently the main doc for the whole switching system, containing several `provider-switch`-specific steps (e.g. "edit the `GROUPS` dict in `status.py`"), needs rewriting into generic steps based on `switches.ini` + `switches/<id>/` directories |
| `vps_oracle/k3s/apps/homepage/k8s/config/services.yaml` | homepage card name/description updated |

Live infrastructure (**confirmed again with the user separately before reaching this step**; not done opportunistically while writing code):

- NPM reverse proxy: `provider.jerome.cloudns.asia → provider-switch:8091` changed to `switchboard.jerome.cloudns.asia → switchboard:8091` (new proxy host + new certificate + access list=self-only, old one taken down).

---

## 4. Test strategy

| Layer | Method |
|---|---|
| Engine (`config.py`) | temp directory + minimal fake scripts (`exit 0`, `printf`) simulating `switches/<id>/`, assert `switches.ini` parsing, concurrent probing, locking, timeout, failure-display behavior — replaces the hand-written `GROUPS` in the current `test_status.py` |
| HTTP (`app.py`) | start the service, monkeypatch the config source with a temp `switches.ini` + fake script directory, curl `/` and `/toggle`, assert page content and `.lock`/switch-script invocation — continues the `TestDoPostWiring` pattern in the current `test_app.py` |
| Real scripts (`jerome-ccr`/`bridget-ccr`) | the scripts themselves are thin (a few shell lines), no unit tests; manual/integration verification via the existing `curl` approach in `ccr/README.md` |

---

## 5. Known constraints and risks

| # | Item | Notes |
|---|---|---|
| C1 | Scripts run as container uid 1001; which host paths they can reach depends on the volumes mounted in `docker-compose.yml` | a new switch that needs a new host path requires an explicit volume in the compose file — that's an infrastructure change, not "pure config", and needs a container rebuild. Deliberately not "mounting `docker.sock`" or broad permissions for convenience: a single web button that can directly control every other container has too large a risk surface, so it's not the default option |
| C2 | `status.sh` failure and "off" are two different states | the engine must distinguish ERROR from off, else a broken probe would be misread as "safely off" (3.3/3.4) |
| C3 | The two CCR script sets duplicate each other | at the current scale (2 near-identical switches) not worth a shared library; revisit when a third isomorphic use case appears |
| C4 | The rename touches live NPM reverse proxy/certificate | a shared-infrastructure change, needs re-confirmation before executing (3.7) |

---

## 6. Open items

None — the implementation details discussed this round (timeout seconds, thread-pool size, lock-file location) already have defaults in the design; if they prove unsuitable during implementation they can be adjusted directly without affecting the overall architecture.
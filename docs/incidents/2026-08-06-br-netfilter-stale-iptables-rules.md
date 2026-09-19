# Incident: br_netfilter activated Docker's stale iptables rules, breaking inter-container connectivity inside a bridge

Date: 2026-08-06
Status: resolved
This file is deliberately not committed to git, kept purely as a faithful record of the investigation.

## Background: the start of the full causal chain

The starting point of this problem is that the user, to free up memory for k3s, manually `docker compose down`'d `programming-learning-platform`, a project not managed by this repo (see the "projects not managed by this repo" section in [deployment-topology.md](../deployment-topology/v1.md)). During the k3s installation it turned out this compose was actually still needed, so the user `docker compose up`'d it again — **this down/up cycle is the true starting point of the chain of problems that followed**, intertwined with this k3s installation work itself, and both are necessary to explain what happened.

## Full timeline (key background from the user + technical investigation woven together)

1. **User action**: `docker compose down` stopped `programming-learning-platform` to free memory for the k3s installation
2. **This task**: Task 1 installs k3s; the systemd unit's `ExecStartPre` runs `modprobe br_netfilter` — this is a standard Kubernetes network precondition. Loading it also turns on the host-wide `net.bridge.bridge-nf-call-iptables`, whose effect is that "even inter-container traffic within the same docker bridge network gets sent to iptables' `raw`/`PREROUTING`/`FORWARD` and other chains for evaluation" — which did not happen before
3. **User action**: found `programming-learning-platform` was still needed, `docker compose up` brought it back. This up created a brand-new bridge (`br-b951f3fb0958`), but when Docker itself had `down`'d the old network earlier, it did not clean up the anti-IP-spoofing rules it had added to the `raw` table — leaving behind several stale `DROP` rules pointing at an old bridge interface (`br-66885a1f7aad`) that no longer existed. Because the exception condition's interface no longer exists, "interface is not equal to a nonexistent thing" is always true, effectively becoming an unconditional drop of all packets destined for these few container IPs
4. **User found**: after `up`, the service was unreachable — because `br_netfilter` had already been turned on in step 2, this was the first time this batch of stale rules actually took effect (before `br_netfilter` was turned on, such stale rules were completely harmless, since pure bridge-internal traffic was never sent into `raw`/`PREROUTING` for matching)
5. **User action**: tried restarting the docker daemon to fix the unreachability — **this restart did not fix `programming-learning-platform`** (the stale `raw` table rules are not cleared by a daemon restart, because they hang on interface names that no longer exist and the daemon restart does not proactively compare against the existing interface list to do that kind of cleanup), but it **reshuffled the IPs of all containers on the `proxy` network, including `npm` and `3x-ui`** — this is exactly the root cause of the subsequent chain of NPM access-list / 3x-ui proxy-unreachable problems (see the other record [2026-08-06-proxy-access-ip-mismatch.md](2026-08-06-proxy-access-ip-mismatch.md); not repeated here, only pointed out in the causal chain)
6. **Follow-up investigation** (focus of this record): the user reported that within `programming-learning-platform`'s docker network, no two containers could reach each other, asking whether this was caused by the k3s-related operations

## Technical investigation

### Step 1: confirm the symptom, rule out surface causes

- `docker exec programming-learning-platform-nginx-1 nc -zv -w3 172.18.0.3 9090` timed out (`Operation timed out`, not "connection refused", meaning packets were dropped at the network layer, not that the application was not listening)
- Tried several container pairs (nginx→prometheus, nginx→mysql, api-server→mysql) all unreachable the same way, ruling out a single flow or single container
- Control group: our own monitoring stack (grafana→prometheus, also bridge-internal interconnect) worked perfectly — confirming it was not a host-wide block, only `programming-learning-platform`'s network was affected

### Step 2: locate the mechanism — confirm it is br_netfilter

`lsmod | grep br_netfilter` confirmed the module was loaded, and `sysctl net.bridge.bridge-nf-call-iptables` showed `= 1`. Ran a decisive control test: temporarily set this sysctl back to `0`, and `programming-learning-platform`'s container interconnect recovered immediately; set it back to `1`, and the problem immediately reproduced. This confirmed the **mechanism** (this switch is at play), but had not yet found **which specific rule** is blocking.

### Step 3: trace where packets actually go

Ruled out the following possibilities in order, each with actual test evidence:
- **bridge port STP state**: `bridge link show` confirmed all ports were `forwarding`, not `blocking`
- **tc/nftables/ethtool-level filtering**: no tc filter on the veth, no XDP drop counter, no extra nftables bridge-family tables
- **ebtables**: rules were empty, policy all ACCEPT
- **ARP cache expiry**: checked the source container's ARP table, the destination MAC address was correct and matched the target container's current real MAC
- **conntrack state**: (this machine initially did not have the conntrack tool installed; after the user authorized it, installed `apt install conntrack` on the spot) live-monitored conntrack events and found **this specific flow never created any record in conntrack from start to finish** — meaning the packets were already handled before entering the connection-tracking system, pointing to the `raw` table (the `raw` table is evaluated before conntrack and is the only place that can drop packets without leaving any conntrack record)

### Step 4: find the actual rules in the raw table

`iptables -t raw -L PREROUTING -n -v -x --line-numbers` listed the full rules and found two paired groups of rules pointing at the same destination IPs (`172.18.0.2` through `172.18.0.8`) but referencing two different bridge interfaces:

```
DROP  !br-66885a1f7aad  ->  172.18.0.3   (4967 packets hit, still accumulating)
...(same pattern for 172.18.0.2/4/5/6/7/8, 7 rules total)

DROP  !br-b951f3fb0958  ->  172.18.0.3   (0 packets hit)
...(same 7 IPs, 7 rules total)
```

`ip link show br-66885a1f7aad` reported `Device "br-66885a1f7aad" does not exist` — confirming this is an already-deleted old bridge. Because iptables evaluates top-down and stops at the first hit, all traffic first hits this group of stale rules pointing at a nonexistent interface and gets dropped, and the new rules (the `br-b951f3fb0958` group) never get a chance to be evaluated — hence showing 0 hits, not because they are fine, but because they never get a turn.

### Step 5: precise fix

Only deleted those 7 stale rules pointing at `br-66885a1f7aad` (`iptables -t raw -D PREROUTING <line-number>`, deleting from largest to smallest to avoid line-number shift), completely leaving `bridge-nf-call-iptables` alone (keeping `1`, the behavior k3s/Cilium needs, untouched). Immediately retested after deletion, and `172.18.0.3:9090` changed from timeout to `open`.

Also swept the entire `raw` table, compared every interface name referenced in rules against the currently-existing interface list from `ip link show type bridge`, and confirmed no other stale rules remained (only rules referencing existing interfaces).

### Step 6: full verification

- All four container pairs in `programming-learning-platform` connect to each other
- Our own monitoring stack (grafana↔prometheus) unaffected
- k3s node status `Ready`, `cilium status` shows `Cilium: OK`
- Full host container status overview, no other anomalies

## Answering a few direct questions

**Is this related to k3s?** Yes, but the relationship is "trigger condition", not "k3s itself has a bug". `br_netfilter` + `bridge-nf-call-iptables=1` is a standard precondition of all mainstream Kubernetes distributions/CNI solutions, and k3s doing this is completely normal and follows the docs.

**Is this a real bug?** Yes, but the bug is in **Docker itself**: when a network is `down`'d/rebuilt, dockerd does not clean up the anti-IP-spoofing rules it added to the `raw` table, leaving stale rules pointing at already-deleted interfaces. This bug is never noticed in a pure Docker environment (with no Kubernetes/CNI components), because pure bridge-internal traffic is never sent into `raw`/`PREROUTING` to be matched against these rules — k3s did not create this bug, it just opened a door for the first time that let this latent stale rule take actual effect.

**Is there a way to avoid it?** Cannot be eradicated (you cannot avoid installing `br_netfilter`, it is a hard precondition for k3s networking; and you cannot fix dockerd's own cleanup logic, that is upstream code). What can be done is **lower the trigger probability** and **detect it earlier**:
- Avoid unnecessary `docker compose down` + `up` cycles, especially avoid frequently down/up'ing the same network in memory-tight situations where you need to temporarily free resources (this was exactly the starting point here)
- If you later encounter the specific symptom of "containers in the same docker bridge suddenly can't reach each other", there is now a complete, reproducible investigation path: use the `sysctl` switch control test to lock down the mechanism → check whether conntrack left any record to judge whether it is stuck in the `raw` table → compare the interface names referenced by `iptables -t raw -S PREROUTING` against the currently-existing interfaces from `ip link show type bridge` to catch the stale rules "referencing a nonexistent interface"

## Relationship to another incident

This daemon restart (step 5, the user tried to fix `programming-learning-platform` but did not succeed) — while it did not solve the problem this record addresses — reshuffled the IPs of `npm` and `3x-ui` on the `proxy` network, and is the starting-point root cause of the "NPM access list unreachable" problem in another incident record ([2026-08-06-proxy-access-ip-mismatch.md](2026-08-06-proxy-access-ip-mismatch.md)). The two incidents look completely unrelated on the surface (one is docker bridge-internal connectivity failure, the other is NPM reverse proxy unreachable), but they are actually two consequences forking out of the same chain of operations, not a coincidence.
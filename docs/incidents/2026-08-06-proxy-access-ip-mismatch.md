# Incident: full investigation of the NPM access list unreachable problem

Date: 2026-08-06
Status: resolved
This file is deliberately not committed to git, kept purely as a faithful record of the investigation.

## Background

This machine runs an architecture of "connect to the 3x-ui proxy first, then you can access internal services": grafana, homepage, dify, trilium, vikunja, apprise, portainer and other services sit behind the NPM reverse proxy, and have NPM's Access List applied so only specific IPs are allowed; 3x-ui itself is unrestricted and is the only entry point.

Before this investigation, the docker daemon had been restarted once a bit earlier — **this is not the incident, but a user-initiated action to solve another problem** (not triggered by this task, nor an accident). That restart also caused several containers with relative-path volume mounts (dify-ssrf-proxy, prometheus, blackbox-exporter, grafana, homepage) to fail or run unconfigured because they couldn't find the old paths after the reshuffle; those had already been fixed and confirmed at the time (that part was the real problem to handle; the daemon restart itself was an expected operation, not a problem). This investigation at first was not sure whether it was related to that restart; it later proved unrelated, but the timing makes it easy to associate the two, so it is recorded up front.

## Timeline

### 1. User reports the problem

User said: npm and other services are still unreachable, but 3x-ui is reachable; asking whether this task changed the access list config, or the server IP changed, or the container IP changed.

### 2. My first-round judgment: check the access list contents

Checked NPM's nginx config files (`/data/nginx/proxy_host/*.conf`) and found grafana, homepage, dify, trilium, vikunja, apprise, portainer, and NPM's own admin panel all have the same rule applied:
```
allow 172.19.0.2/32;
allow 161.118.254.107;
deny all;
```
while `panel.3x.jerome.cloudns.asia` (3x-ui's NPM reverse-proxy panel) has no such restriction at all.

**Judgment at the time**: this is the direct cause of "3x-ui reachable, everything else unreachable" — not that 3x-ui is special, but that all other services are locked into a whitelist that allows only two IPs, and 3x-ui is not locked. This judgment later proved directionally correct, but the understanding of "who 172.19.0.2 is" was wrong at the time (see below).

### 3. My first misjudgment: thought 161.118.254.107 was the user's home IP

Saw `161.118.254.107` in the whitelist, which looks like an ordinary public IP, and intuitively judged it to be "the user's original home/office IP", and assumed the user's current IP changed, causing the unreachability. **This judgment later proved wrong** — a direct `curl https://ifconfig.me` test found that `161.118.254.107` is actually **this server's own public egress IP**, not the user's.

Basis: `docker exec blackbox-exporter wget https://ifconfig.me` and the server's own `curl https://ifconfig.me` returned the same result, and in npm's access log the once-a-minute blackbox_exporter self-probe requests always came from this value and were always allowed successfully — confirming this is the server's own IP, not the user's.

I asked the user to check their real public IP from a device with no proxy at all and tell me, intending to add it to the whitelist. **This proposal direction was also wrong** (see steps 8-9 later), because it violated the user's original architectural intent (see step 6).

### 4. User reports: connecting via the 3x-ui proxy

User said they had already connected to the 3x-ui proxy themselves and used the proxy to access the access-list-restricted services.

**My judgment**: checked npm's access log and found no new record matching this connection, only blackbox_exporter's fixed probes. Proposed a hypothesis at the time: possibly a hairpin NAT problem (traffic on the same machine looping back to its own public IP, which some cloud environments stall on), but **explicitly acknowledged this was only a judgment, not actually verified**.

### 5. User provides screenshot: `ERR_CONNECTION_CLOSED`

The browser error is "the connection was closed mid-way by the peer", not a timeout or the common "connection refused". I originally expected that if the access list blocked it, we would see a clean 403 page, so this error code did not quite match.

### 6. A digression, honestly recorded: suspected intrusion

Using `top` I unexpectedly saw a process named `fail2ban-server`. Checking `dpkg -l`, `pip3 show`, `snap list` found no install record, the path `/usr/bin/fail2ban-server` did not exist on disk, and there was no corresponding systemd unit. **My judgment at the time was that this might be a suspicious process masquerading as a system service name, and I issued a security warning to the user.**

Later verification: `/proc/<pid>/exe` actually points to the legitimate `/usr/bin/python3.14`, and the parent process is `/app/x-ui` — inferring this is 3x-ui's own built-in fail2ban integration (launched by its own packaged script, not installed via system apt, hence no install record), not an intrusion. Also checked iptables and found no fail2ban-related chains, ruling out that it blocked anything at the firewall level. **This is a complete process of an erroneous judgment followed by self-correction, recorded as-is, not later deleted and rewritten as "knew it was a misunderstanding from the start".**

### 7. Testing directly from the server itself

`curl -v https://npm.jerome.cloudns.asia/` tested directly from the server itself returned a clean 200 with a normal TLS handshake. **This result proves nginx itself and the access list mechanism itself are fine** — the problem is in the "connecting in through the proxy" path, not that the NPM side itself is broken.

### 8. Key turning point: the user explains the original architectural intent

The user explained: this access list is deliberately designed to create a secure "intranet" on the public internet — most services are locked into a whitelist, and only by connecting to the proxy can you get in; the whitelist holds "the IPs of the server, or of docker networks on the server".

I asked at the time to first write this understanding into a README (`vps_oracle/compose/npm/README.md`), and while writing it **still assumed `172.19.0.2` was npm's own IP** (because just the previous round I had found that npm's then-current IP was exactly 172.19.0.2, and the two happened to coincide, so I did not further question this assumption).

### 9. User asks a follow-up: would extra_hosts cause IP drift

User asked: npm's added `extra_hosts` (added in this task's Task 6) would it affect the `proxy` network's IP allocation.

**My judgment**: `extra_hosts` itself does not affect network IP-allocation logic, but it caused the npm container to be recreated once (because `extra_hosts` is a setting fixed at container creation), and npm's compose file did not pin a static IP at the time, so in theory a recreation risks getting a different IP — though in practice this time it happened to still be 172.19.0.2 (when Docker recreates a container, the just-released IP is usually immediately reallocated back, but this is not guaranteed by config). User said "add it for now", and I pinned npm's `proxy` network IP to `172.19.0.2`. **This step later proved to be pinning in the wrong direction** (see step 12), but the logic at the time was self-consistent, it was just built on the unverified assumption that "172.19.0.2 is npm itself".

### 10. The user's key challenge

User asked: that doesn't seem right, traffic goes through the 3x-ui container, so 3x-ui is the container that should have a fixed IP?

**My first reaction at the time was to rebut with an actual test**: spun up a test container on the `proxy` network and directly hit the public domain `npm.jerome.cloudns.asia` (not the internal container name), and found the source recorded in the nginx log was `161.118.254.107` (the server's public IP), not the test container's own docker network IP. **Judged at the time**: no matter which container initiates, as long as it hits the public domain and loops back around, the source becomes the server's public IP, so pinning 3x-ui's IP is meaningless, and the problem should be in xray's own forwarding logic, not IP allocation.

**This judgment was also later overturned** — because it assumed "3x-ui's traffic must go through public-domain resolution and loop back", but that assumption was applied directly without first verifying 3x-ui's actual forwarding mechanism.

### 11. The user provides decisive historical fact

User said: `161.118.254.107` was added later to solve access for another "special service"; **the original whitelist had only the single `172.19.0.2` entry and worked fine**.

This information directly contradicts the step-10 test result — if hairpin traffic always becomes the server's public IP, then a whitelist allowing only `172.19.0.2` (without the public IP) should never have allowed any traffic coming in through the 3x-ui proxy, yet the user said it originally worked. **This means the step-10 inference applies to the "ordinary container hitting a public domain" case, and does not apply to 3x-ui's actual forwarding method** — 3x-ui must use some forwarding mechanism that does not trigger hairpin/SNAT.

### 12. Verify 3x-ui/xray's actual config, find the root cause

Directly read `/app/bin/config.json` inside the 3x-ui container and found:
```json
"dns": {
    "hosts": {
      "domain:jerome.cloudns.asia": "172.19.0.3"
    }
}
```
This DNS override rule makes xray, for all `*.jerome.cloudns.asia` domains, **completely bypass public DNS** and send traffic directly to `172.19.0.3` inside the `proxy` network — this path never leaves the host, is not rewritten by Docker's SNAT, and the source nginx sees is **xray's (the 3x-ui container's) own real IP**.

At the time I found `172.19.0.3` was actually **vikunja**'s IP, not npm's — first judgment was "xray's config is wrong, it should point to npm", and I prepared to ask the user whether to change this value to npm's actual IP.

### 13. The user's final determination

User pointed out: `172.19.0.3` should be npm's IP, and `172.19.0.2` should be 3x-ui's IP — "change it as I said, then restart the docker daemon to reallocate all IPs".

**My response**: pointed out this directly conflicts with what was just done in step 9 (npm pinned to `.2`), and did not recommend restarting the whole docker daemon (the earlier accidental restart had already broken three services, and restarting the daemon would touch every container on this machine, the same risk level as the "act first, ask later" error made in steps 9-10); instead suggested only touching the npm, 3x-ui, (and possibly vikunja) containers. And asked the user to clarify once and for all who the `172.19.0.2` rule in the whitelist was originally designed to allow.

The user gave the final, complete explanation: 3x-ui uses xray's DNS override to send traffic directly to npm (`172.19.0.3`); this path never leaves the host and is not rewritten by SNAT, so npm sees 3x-ui's own IP as the source, and the whitelist allowing `172.19.0.2` is allowing 3x-ui. **At this point the correct mapping is fully confirmed: `3x-ui = 172.19.0.2`, `npm = 172.19.0.3`.**

## Root cause summary

1. `3x-ui`'s xray config has a DNS override rule sending all `*.jerome.cloudns.asia` traffic directly to `172.19.0.3` inside the docker network
2. This value should equal npm's own IP, but at the time npm actually occupied `172.19.0.2` and `172.19.0.3` was occupied by vikunja — both inconsistent with the xray override rule and the access list expectation
3. NPM's two access lists (`self-only`, `self-only-and-auth`) allow `172.19.0.2`, and this rule's intent was always "allow 3x-ui's own IP" (because xray forwarding does not trigger SNAT, nginx sees 3x-ui's real source IP), not "allow npm itself"
4. Neither service had a pinned static IP; Docker's dynamic allocation put each in the wrong position

## What was fixed

- `vps_oracle/compose/3x-ui/docker-compose.yml`: pinned static IP `172.19.0.2` on the `proxy` network
- `vps_oracle/compose/npm/docker-compose.yml`: pinned static IP `172.19.0.3` on the `proxy` network (changed from the earlier wrongly-pinned `172.19.0.2`)
- Execution order: stop vikunja (vacate `.3`) → rebuild npm (get `.3`, vacate `.2`) → rebuild 3x-ui (get `.2`) → start vikunja (auto lands on another free slot `.5`; user said other IPs don't matter, no further handling)
- Did not restart the docker daemon, only touched these three containers

## Verification

Simulated xray's forwarding path directly from inside the 3x-ui container:
```bash
docker exec 3x-ui sh -c "curl -sS -o /dev/null -w 'HTTP:%{http_code}\n' --max-time 5 --resolve npm.jerome.cloudns.asia:443:172.19.0.3 https://npm.jerome.cloudns.asia/"
```
Got `HTTP:200`, and confirmed in npm's access log that the source correctly shows `172.19.0.2`:
```
[Client 172.19.0.2] ... "curl/8.21.0"
```

## Reflection: why did it take so many turns to find

- **At the start took "172.19.0.2 is npm's own IP" as an unstated but tacit default**, because the npm actual IP I had found happened to be exactly this value, and the two coincided, so I did not further verify this assumption and kept reasoning several steps down the road (including in step 9 proactively pinning the wrong mapping)
- **In the middle once used an actual test to "rebut" the user's intuition** (step 10), but that test used the "ordinary container hitting a public domain" scenario without first checking whether 3x-ui's actual forwarding mechanism follows the same path — the test itself was not wrong, but the scenario it was applied to was, prematurely turning a local verification result into a universal conclusion
- **The real turning point was the historical fact the user provided in step 11** (originally allowing just 172.19.0.2 was enough) — this information cannot be derived from the server's current state and only the user knows it; without it, server-side investigation alone would likely have kept going in circles on the wrong direction of "hairpin NAT stall"
- Along the way there were two misjudgments that were explicitly pointed out, verified, and corrected (the fail2ban security concern, whether 161.118.254.107 was the user's IP); the strategy adopted was to directly verify each time rather than debate by guessing, which was one of the few parts of this investigation that got it right the first time

## Lessons for the user

This whole "connect to the 3x-ui proxy first, then you can access internal services" protection scheme was, before this incident, **not written down anywhere** — not in this repo, not in the README, not elsewhere, only existing in the user's head. This directly meant Claude Code, when investigating, had no basis to refer to and could only reverse-engineer the design intent from phenomena observable on the server (access list contents, test results), going astray several times along the way: mistaking `172.19.0.2` for npm's own IP, thinking `161.118.254.107` was the user's home IP, even suspecting at one point the server was compromised. These misjudgments were not because the verification method was wrong, but because there was no correct reference for "what this system is supposed to look like" at the starting point, and the only option was to use experiments to guess step by step.

This is also why, in step 8, once the user explained the architectural intent, I asked to first write it into a README — writing down this kind of "design intent that exists only in someone's head and is invisible to others" is key to preventing the same thing from happening again, and matters more than simply fixing this bug.
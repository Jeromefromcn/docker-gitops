# sl-ledger

The securities-lending ledger of [java-hands-on](https://github.com/Jeromefromcn/java-hands-on),
deployed by its stage 14 (packaging and delivery). Everything it needs runs in the `sl-ledger`
namespace: the ledger (two replicas), Postgres, Redis, a single Kafka broker, and a WireMock that
stands in for the market-data source and for the identity provider's key set. Nothing is shared
with another namespace. Synthetic data only.

| Manifest | What |
|---|---|
| `k8s/ledger.yaml` | Deployment, Service, ServiceAccount; probes, `preStop`, resources, shutdown budget |
| `k8s/accrual-cronjob.yaml` | The daily accrual as a suspended CronJob, run by hand |
| `k8s/postgres.yaml`, `redis.yaml`, `kafka.yaml` | The ledger's own state |
| `k8s/stubs.yaml` | Market-data prices and the JWK set (public key only) |

Credentials: `k3s/sealed-secrets/secrets/sl-ledger-credentials.sealed.yaml`. Admission: the image is
verified by `restrict-image-registry` against java-hands-on's `ci` workflow identity, and the pods
are held to the restricted profile by `restricted-self-built`.

## Promote a release

The java-hands-on pipeline builds, scans, pushes and signs; it does not deploy. Take the digest
from the run summary of a green `ci` run on `main` and change it in **both** `k8s/ledger.yaml`
and `k8s/accrual-cronjob.yaml`, in one commit: `sl-ledger: promote <short sha>`. Push; ArgoCD
syncs; the rolling update keeps two ready pods throughout (`maxUnavailable: 0`).

## Roll back

`git revert` the promotion commit and push. The previous digest is still in GHCR and still
signed; nothing is rebuilt. A rollback does not undo what the bad release booked: entries in the
ledger stay and are corrected by the ledger's own processes.

## Talk to it

The API is not exposed outside the cluster. Tokens are signed with a key held outside every
repository (on this host, `~/.config/sl-ledger/k3s-jwt.pem`) by java-hands-on's
`infra/delivery/token.sh`, with issuer `https://sl-ledger.k3s.invalid`:

```bash
TOKEN=$(infra/delivery/token.sh ~/.config/sl-ledger/k3s-jwt.pem https://sl-ledger.k3s.invalid ops-a ledger-ops)
kubectl -n sl-ledger run curl --rm -i --restart=Never --image=curlimages/curl:8.16.0 -- \
  -s -H "Authorization: Bearer $TOKEN" http://sl-ledger:8080/actuator/info
```

The management port (8081: probes, info, metrics) is the pods' own and is not in the Service.

## Run the accrual

```bash
kubectl -n sl-ledger create job accrual-$(date +%Y%m%d-%H%M) --from=cronjob/sl-ledger-accrual
```

It reads the day-count rollout once, at its start, and books today's date (Hong Kong).

# kube-state-metrics

One cluster-wide instance (Helm chart `prometheus-community/kube-state-metrics`,
values here, Application `k3s/argocd/apps/kube-state-metrics.yaml`), shared by
every Prometheus that needs Kubernetes object state. KSM is a per-cluster
singleton by convention: running one per consumer only multiplies API-server
watches for the same data.

- **Placement:** pinned to vps_oracle (`instance-20260321-2043`). vps-oracle2's
  CPU requests are the lab's ceiling, and KSM should keep reporting when the
  chaos node is the thing that broke.
- **Consumers:**
  - lab Prometheus (`k3s/apps/lab-environment/`) — scrapes
    `kube-state-metrics.kube-system.svc:8080` and keeps only
    `namespace="lab-environment"`.
  - vps_oracle compose Prometheus — **not wired yet.** NodePort 30115 is
    reserved for it; it needs an `npm-nodeport-relay` instance first
    (`vps_oracle/host-native/npm-nodeport-relay/README.md`).
- **Check:** `curl -s http://10.0.0.95:30115/metrics | grep -c '^kube_pod_info'`

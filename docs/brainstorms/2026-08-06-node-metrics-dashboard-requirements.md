---
date: 2026-08-06
topic: node-metrics-dashboard
---

# Node Metrics Dashboard (Phase 3.5)

## Problem Frame

Three used OptiPlex 7050s (i5-7500T, 16 GB RAM, 256 GB NVMe) run the cluster, and
there is currently no way to see whether any of them is thermally throttling,
filling its disk, or under memory pressure. The 256 GB NVMe is already called out
in `homelab-roadmap.md` as "the real limit" — a disk quietly filling is the most
likely way this homelab breaks, and today it would only be noticed by SSH-ing in
and running `df -h`.

This is Phase 3.5 of `docs/PROJECT-PLAN.md`, already scoped there as
kube-prometheus-stack. This brainstorm confirms that choice against SigNoz,
settles component placement, and resolves the prerequisite ordering that was
blocking it.

Priority is **hardware visibility first, on a foundation that grows** — no
throwaway work.

## Requirements

**Metrics**

- R1. Per-node CPU utilisation, memory usage, disk usage and disk I/O, and
  network bandwidth, for all three nodes, visible in a single Grafana view.
- R2. Per-node CPU/system temperatures, visible over time. This is *not* covered
  by kube-prometheus-stack's bundled dashboards and requires a dedicated panel.
- R3. Kubernetes API server request rate (this is what "requests/min" resolved
  to — control-plane load, not application HTTP traffic).
- R4. `kubectl top nodes` and `kubectl top pods` work (metrics-server), per the
  existing Phase 3.5 checklist.

**Access**

- R5. Grafana reachable from the laptop at a stable address on the LAN, without
  running a command first. Plain HTTP is acceptable for this milestone.

**Alerting**

- R6. Alerts fire to the user's phone via ntfy for the failure modes that
  actually threaten this hardware: disk usage above threshold, node down,
  thermal throttling, and sustained memory pressure.
- R7. The bundled alert rule set is pruned so that no alert fires permanently.
  Many kube-prometheus-stack defaults assume an HA control plane and will be
  perpetually red on a single-control-plane 3-node cluster; a permanently-firing
  alert trains the user to ignore the channel, which defeats R6.

**Operational fit**

- R8. Prometheus retention is capped in both time and size so metrics cannot
  fill the NVMe — the roadmap's stated target is ~15 days with a ~10–20 GB
  `retentionSize` cap.
- R9. All components carry resource requests and limits, so monitoring cannot
  starve the workloads it exists to observe.
- R10. Every in-cluster component except the Argo CD bootstrap itself is defined
  in git and applied by Argo CD.

## Success Criteria

- Opening Grafana shows live CPU, RAM, disk, network and temperature for all
  three nodes, with history going back at least a day.
- Deliberately filling a disk on one node produces an ntfy notification on the
  phone within minutes.
- After 48 hours of normal operation, the alert channel is silent — no
  permanently-firing rules.
- `df -h` and `ssh` are no longer the first tools reached for when a node feels
  slow.
- When apps and agent sandboxes land later, they are observed by adding a
  ServiceMonitor — not by rebuilding the monitoring stack.

## Scope Boundaries

- **No SigNoz.** Revisit when application traces are actually needed (Phase 4+),
  not for node metrics. See Key Decisions.
- **No distributed tracing, and no log aggregation.** Loki is explicitly a later
  addition per the roadmap ("metrics before logs").
- **No application-level HTTP metrics** (requests/min, error rate, latency per
  app). Requires ingress-nginx plus apps that do not exist yet. The dashboards
  are additive when they do.
- **No TLS, no local DNS, no cert-manager** on the critical path. Phase 2.75
  becomes a follow-up; Grafana over plain HTTP counts as done.
- **No HA and no replicated storage.** Single-replica Prometheus on node-local
  storage. Longhorn is not justified on 256 GB disks.
- **No long-term metric retention.** 15 days is the design point; anything
  needing a year of history is a different system.
- **No out-of-band monitoring.** In-cluster monitoring goes down with the
  cluster — accepted knowingly, see Key Decisions.

## Key Decisions

- **kube-prometheus-stack, not SigNoz.** SigNoz is OTel-native APM whose value is
  traces correlated with logs and metrics, for applications — of which there are
  currently none. Two concrete disqualifiers for *this* request: its host metrics
  come from the OTel Collector's `hostmetrics` receiver, which has no temperature
  scraper (R2 would be unmet), and its ClickHouse backend realistically wants
  6–8 GB RAM versus roughly 2.5 GB fleet-wide for kube-prometheus-stack — half of
  one 16 GB node, to watch three machines. Reconsider at Phase 4+ when Rails and
  agent-sandbox workloads exist and tracing is the actual need.

- **Prometheus, Grafana and Alertmanager are pinned to a designated worker; never
  the control plane.** Two reasons. First, `roles/control_plane` never removes
  kubeadm's `node-role.kubernetes.io/control-plane:NoSchedule` taint, so hosting
  there would mean untainting node-1 — which admits not just Prometheus but every
  future workload to the control plane. Second, node-1 runs etcd, which is
  fsync-latency-sensitive, and Prometheus TSDB compaction is write-heavy; sharing
  one NVMe is a known cause of etcd fsync spikes, apiserver flakiness and
  spurious leader elections. That failure is especially bad here because the
  monitoring stack would be *causing* the instability it is meant to reveal.

- **node-exporter runs on all three nodes as a DaemonSet.** Not a placement
  choice — it is the source of R1 and R2, and a node without it is invisible.

- **The chosen worker is effectively permanent.** With local-path-provisioner the
  PV is a directory on whichever node the pod first schedules onto, and the PVC
  acquires node affinity. Pick deliberately rather than letting the scheduler
  decide. Per `homelab-roadmap.md` line 122, it must not be the node that later
  carries the agent-sandbox taint.

- **Argo CD is bootstrapped imperatively; everything else is an Argo app.** This
  resolves a conflict that surfaced during the brainstorm: local-path-provisioner,
  MetalLB and ingress-nginx are in-cluster state too, so installing Phase 2.5 by
  hand would leave four components outside git — the same adoption debt the
  Argo-first choice was meant to avoid. Bootstrapping Argo CD imperatively is the
  standard GitOps exception. Resulting order:

  1. Bootstrap Argo CD (verify once via `kubectl port-forward`)
  2. Argo deploys local-path-provisioner → MetalLB → ingress-nginx
  3. Argo deploys metrics-server and kube-prometheus-stack
  4. Grafana reachable via ingress on the LAN

  Monitoring is therefore the *last* platform app rather than the first, but
  nothing ever needs adopting.

- **Alerts go to ntfy.** Free, no account, phone app, self-hostable in-cluster
  later, and a single Alertmanager webhook receiver. Chosen over email
  specifically because email is easy to ignore.

- **In-cluster monitoring dies with the cluster — accepted.** If the cluster is
  down, the dashboard that would explain why is down too. An out-of-band exporter
  or external scrape was considered and rejected as more moving parts than a
  3-node homelab warrants.

## Dependencies / Assumptions

- **Depends on Phase 2.5 landing first** (local-path-provisioner for the
  StorageClass, MetalLB + ingress-nginx for R5), and on Argo CD from Phase 3.
  This is the single largest cost in the work and was accepted deliberately over
  a faster NodePort-based path.

- **This may require an Ansible-layer change, not only a cluster-layer one.** R2
  depends on `hwmon` sensor data being present on the hosts, which on these
  machines likely means the `coretemp` kernel module being loaded and possibly
  `lm-sensors` installed. `roles/kubernetes_node` already manages kernel modules
  (`overlay`, `br_netfilter`), so that is the natural home — meaning this feature
  may cross the Ansible/Argo boundary described in `CLAUDE.md`.

- **Assumption — Prometheus pins to node-3, and the future agent-sandbox taint
  goes on node-2.** The choice is arbitrary today but effectively permanent once
  the PVC binds. Confirm before first deploy.

- Assumes the ~2.5 GB fleet-wide footprint is acceptable against 48 GB total RAM.

## Outstanding Questions

### Deferred to Planning

- [Affects R2][Needs research] Does node-exporter's `hwmon` collector surface
  usable CPU package temperatures on the OptiPlex 7050 (i5-7500T), and does that
  require loading `coretemp` and/or installing `lm-sensors` on the hosts first?
  Verify on a real node before designing the panel.
- [Affects R2][Technical] Which Grafana dashboard provides the temperature view —
  an existing community dashboard, or a custom panel? Bundled
  kube-prometheus-stack dashboards do not cover it.
- [Affects R7][Technical] Which bundled alert rules must be disabled for a
  single-control-plane 3-node cluster to keep the channel quiet?
- [Affects R6][Technical] Hosted `ntfy.sh` or self-hosted in-cluster? Self-hosting
  is tempting but creates a circular dependency — the alerting path would depend
  on the cluster it is alerting about.
- [Affects R8][Technical] Exact retention time and `retentionSize` values, and
  the resulting worst-case disk footprint on the 256 GB NVMe.
- [Affects R10][Technical] Where the Argo CD app-of-apps manifests live — the
  `clusters/` directory is described in `README.md` but does not yet exist.

## Next Steps

→ `/ce:plan` for structured implementation planning.

Note for planning: the prerequisite chain (Argo CD bootstrap → local-path +
MetalLB + ingress-nginx → metrics-server + kube-prometheus-stack) is large enough
that it likely wants to be staged rather than planned as one unit. Confirm the
node-3 assumption before anything binds a PVC.

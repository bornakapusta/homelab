# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code for a 3-node Kubernetes homelab (3× Dell OptiPlex 7050, Ubuntu 26.04 LTS "resolute"). Uses Ansible for machine provisioning and kubeadm for cluster bootstrap. **Ansible owns the machines, a small bootstrap platform layer, and Argo CD itself. Argo CD owns everything declared under `clusters/home/` (cert-manager, Rancher, kube-prometheus-stack). Two controllers must never reconcile the same object: moving an Ansible-owned component into Argo CD is one atomic change that adds the Application and deletes the role.**

## Commands

All commands run from repo root via Makefile:

```bash
make deps       # install required Ansible collections
make check      # syntax + local safety-gate tests + ansible-lint (touches no node)
make hooks      # install the git pre-commit hooks (lint + gitleaks secret scan)
make test       # molecule test -s hardening (needs Docker; touches no node)
make ping       # verify SSH to all nodes
make nodes      # ansible-playbook site.yml (configure nodes, idempotent)
make cluster    # ansible-playbook cluster.yml (kubeadm init + CNI + join workers)
make platform   # ansible-playbook platform.yml (MetalLB + Traefik + local-path + Metrics Server + Argo CD)
make metrics    # reconcile Metrics Server and print current node CPU/memory
make storage    # reconcile local-path-provisioner (default StorageClass)
make argocd     # reconcile Argo CD and its homelab-root app-of-apps
make all        # nodes + cluster in one go
make hosts      # print the /etc/hosts lines THIS LAPTOP needs (API + web UIs)
make status     # kubectl get nodes + pods using fetched kubeconfig
```

Run `make check` before `make nodes` — the tree passes ansible-lint's `production`
profile with an empty `skip_list`, and should stay that way. `make hooks` wires the
same lint into a pre-commit hook alongside `gitleaks`; the hook is convenience,
`make check` is the gate (hooks are bypassable with `--no-verify`).

**`make test` is the only Molecule test.** It runs the `hardening` role verbatim
against an Ubuntu 26.04 container with real systemd as PID 1 — no mocked handlers —
then checks idempotency and asserts on the resulting sshd/apt/ufw state. Only
`hardening` has a scenario: the other roles need a real kernel (swap, modprobe,
sysctls) or a live API server, so a container would prove nothing. `make check`
also runs controller-only safety and transformation tests for platform roles. If
you add a scenario, put it in `ansible/molecule/<name>/`, **not** inside the role — a
scenario nested in a role makes molecule demand a `galaxy_info` block with a
Galaxy namespace, which these roles deliberately do not have.

**`make nodes` is also a patch event.** The `base` role runs `apt upgrade`, so every
run may pull a kernel. `site.yml` is `serial: 1` + `any_errors_fatal` so a bad change
stops at the first node instead of hitting all three. Nothing reboots automatically;
the base role reports pending reboots and you drain by hand, one node at a time.

**`make status` needs `k8s.home.arpa` to resolve on your laptop.** The nodes get an
`/etc/hosts` entry from the `base` role; your laptop does not. Run `make hosts` once.

Run playbooks directly from `ansible/` dir when using tags:
```bash
cd ansible
ansible-playbook site.yml --tags hardening
ansible-playbook site.yml --tags kubernetes
```

Reset a broken cluster:
```bash
# On each node: sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d
make cluster
```

## Architecture

### Three-playbook design
- **`site.yml`** — idempotent node configuration. Re-run freely. Applies roles: `base` → `hardening` → `kubernetes_node`. Gets all nodes to an identical kubeadm-ready state.
- **`cluster.yml`** — one-time cluster bootstrap. Runs `control_plane` role on the CP node, then `worker` role on workers. Safe to re-run (skips init/join if already done via stat checks on `/etc/kubernetes/admin.conf` and `/etc/kubernetes/kubelet.conf`).
- **`platform.yml`** — bootstrap for cluster services. It installs checksum-pinned native-mode MetalLB, digest-pinned Traefik at `192.168.178.240`, local-path-provisioner (default StorageClass), checksum/image-pinned Metrics Server, and finally digest-pinned Argo CD plus the `homelab-root` Application. The MetalLB `.240-.250` pool sits above the router's confirmed `.20-.200` DHCP range.

### GitOps layer (`clusters/home/`)
`homelab-root` (applied by the `argocd` role) watches `clusters/home/apps/` on `main` of the public GitHub repo, with automated sync + prune + selfHeal. Each file there is one Argo CD `Application` wrapping a Helm chart with an exact `targetRevision` and digest-pinned images in `valuesObject`. **Changes reach the cluster by pushing to `main`, not by running Ansible.**

| App | Namespace | Notes |
|---|---|---|
| `cert-manager` | `cert-manager` | wave 0; issues Rancher's TLS cert |
| `rancher` | `cattle-system` | wave 1; `rancher.home.arpa`; 2.15.x is the first line certified for k8s 1.36 |
| `kube-prometheus-stack` | `monitoring` | wave 1; `grafana.home.arpa`; Prometheus hostNetwork on `monitoring_host` (node-3), 15d/15GB retention, Alertmanager off |
| `home-dns` | `home-dns` | standalone CoreDNS on MetalLB `192.168.178.241`: `*.home.arpa → .240`, `k8s.home.arpa → .11`, rest → FRITZ!Box. The FRITZ!Box advertises it to DHCP clients, so it is a **whole-house dependency** |

**Nodes never resolve through `home-dns`.** The `base` role pins each node's resolver to `node_dns_servers` (the router) via networkd drop-ins and ignores DHCP/RA DNS (`ansible-playbook site.yml --tags dns`). Otherwise a cold boot deadlocks: a node can't pull images through a DNS server that runs on itself.

**Rancher is read-only for anything Ansible or Argo CD owns.** Its UI can edit any object; such an edit is either reverted by selfHeal or silently drifts from git. Its bundled Fleet stays idle (no `GitRepo` objects). Initial passwords for Argo CD, Rancher and Grafana are generated in-cluster, never committed; each app/role README says how to read them.

`monitoring_host` in `group_vars/all.yml` is repeated as a nodeSelector in `kube-prometheus-stack.yaml` (Argo CD cannot read Ansible vars) — change both together. Because Prometheus uses hostNetwork, its scrapes come from a trusted node IP; `hardening` opens only `9090` to the Pod CIDR on that host, for Grafana.

### Ansible roles (`ansible/roles/`)
Order in `site.yml` matters — see the note under `automation_user`.

| Role | Purpose |
|---|---|
| `preflight` | asserts required vars and settings that `kubeadm init` bakes into certs; fails on the controller before any node is touched |
| `base` | hostname, timezone, chrony, apt upgrade, base packages, WiFi power-save off, Tailscale, pending-reboot reporting |
| `automation_user` | dedicated `ansible` account, its own SSH key, validated sudoers drop-in |
| `hardening` | SSH lockdown (drop-in config), ufw firewall, unattended security upgrades (auto-reboot disabled) |
| `kubernetes_node` | swap off, kernel modules (overlay, br_netfilter), sysctls, containerd (from Docker repo, SystemdCgroup=true, pinned), kubelet/kubeadm/kubectl pinned+held, kubelet `--node-ip` pinned |
| `control_plane` | kubeadm init, digest-pinned Cilium CNI, kubeconfig fetch, generate join command |
| `worker` | join cluster using token from control_plane, wait for registration, label node |
| `metallb` | checksum-pinned native manifest, digest-pinned images, Layer 2 address-pool safety gate |
| `traefik` | digest-pinned Helm release, standard Ingress only, fixed MetalLB address |
| `metrics_server` | checksum-pinned parsed manifest, digest-pinned image, worker-only current CPU/memory API |
| `local_path_provisioner` | checksum-pinned manifest, digest-pinned images, workers-only default StorageClass |
| `argocd` | digest-pinned Helm release, `argocd.home.arpa`, applies the `homelab-root` app-of-apps |

`automation_user` **must** run before `hardening`: the account has to exist and be
listed in sshd's `AllowUsers` before `hardening` reloads sshd.

Every role has a `README.md` (purpose, arguments, idempotency, **rollback**) and a
`meta/argument_specs.yml` that is validated on every run. When you change a role's
inputs, update its argument spec — that file, not the comments in `defaults/main.yml`,
is the enforced interface. `preflight` is the deliberate exception: its argument spec
declares almost nothing, because argument validation runs before its tasks and would
replace its explanatory `fail_msg` text with a generic "missing required arguments".

**`meta: flush_handlers` in `kubernetes_node` is play-global, not role-scoped.** In
`site.yml` it is what actually fires `hardening`'s `Reload sshd` / `Reload ufw`
handlers, mid-`kubernetes_node`. Safe only because `hardening` runs `sshd -t` before
anything reloads. Re-check this if you reorder the roles.

### Two-user model
`admin_user` (`borna`) is the human break-glass login. `ansible_service_user`
(`ansible`) is the automation account — separate SSH key, `from=`-restricted,
locked password, own validated sudoers file. Both are in `ssh_allowed_users`, and
`preflight` refuses to run if the account Ansible is connecting as is not on that
list (which would lock you out of every node on the next sshd reload).

This is separation for audit and key rotation, **not** privilege reduction —
Ansible needs root either way, so both accounts hold `NOPASSWD:ALL`.

`ansible_user` still points at `admin_user`. Switching it to the automation account
is a deliberate 4-step rollout documented in `group_vars/all.yml`.

### Key config files
- **`ansible/group_vars/all.yml`** — single source of truth for all *user-facing* variables (IPs, versions + their sha256 digests, users, pod CIDR, control plane endpoint). Role-internal lists live in that role's `defaults/main.yml` (e.g. `base_packages`) — deliberately not duplicated here, because a duplicate would silently win and edits to the role default would become no-ops.
- **`ansible/inventory.ini`** — node IPs and group membership (`control_plane`, `workers`, `k8s_cluster`)
- **`ansible/ansible.cfg`** — privilege escalation, SSH pipelining
- **`.ansible-lint`** — `production` profile, **no `skip_list`**. Keep it empty.
- **`.pre-commit-config.yaml`** — gitleaks + the same ansible-lint (`make hooks`)

### Inventory layout
```
[control_plane]  node-1 (192.168.178.11)
[workers]        node-2 (192.168.178.44), node-3 (192.168.178.66)
[k8s_cluster:children]  control_plane + workers
```

## Conventions

- Roles use `community.general` and `ansible.posix` modules directly, pinned to major ranges in `requirements.yml` (install with `make deps`)
- Do **not** set `stdout_callback = yaml` in `ansible.cfg` — that short name resolves to `community.general.yaml`, removed in community.general 12.0.0, and aborts every run. Use `stdout_callback = default` + `result_format = yaml`.
- Handlers live in each role's `handlers/main.yml` — hardening has `Reload sshd`/`Reload ufw`; kubernetes_node has `Reload sysctl`/`Restart containerd`/`Restart kubelet`
- The kubeconfig is fetched to `ansible/kubeconfig` (gitignored)
- `autoinstall/user-data` contains secrets and is gitignored; only `user-data.example` is tracked
- Versions **and their sha256 digests** are pinned together in `group_vars/all.yml`. The two apt signing keys plus MetalLB and Metrics Server manifests are checksum-verified; Cilium, MetalLB, Traefik, and Metrics Server runtime images use immutable digests. Never weaken those checks. Regenerate key or manifest digests with `curl -fsSL <url> | sha256sum`, and obtain the Cilium chart digest with `helm pull oci://quay.io/cilium/charts/cilium --version <version>`. The k8s `Release.key` digest is stable across minor bumps.
- Anything writing to `/etc/sudoers.d/` must use `validate: visudo -cf %s` — a malformed file makes `sudo` unusable on every node at once
- Any task whose command line or output carries a secret gets `no_log: true`. Prefer removing the secret instead where possible (e.g. `kubeadm init --skip-token-print`), since `no_log` censors failures too
- **Variable naming is enforced by lint, not convention.** Registered and `set_fact` variables are `__<role>_`-prefixed (internal); role defaults are `<role>_`-prefixed. The one intentional exception is `control_plane_join_command`, a published output of `control_plane` read by `worker` through `hostvars` — interface, not internal. Ansible has no namespaces and `site.yml` runs all five node roles in a single play, so they share one namespace for the whole run.
- **Roles never reference `groups[...]`.** Group names are inventory *data*; `group_vars/all.yml` resolves them once into `control_plane_host`, `worker_hosts`, `cluster_hosts`, `node_ips`, and the roles consume those. The sole exception is `preflight`'s "exactly one control-plane node" assertion, which is *about* the inventory's shape.
- **Every file a role writes carries a provenance header and `backup: true`.** Use the role's `__<role>_managed_header` from `vars/main.yml`, not `ansible_managed` — that variable is injected by the `template` action plugin only and is **undefined** inside `copy: content:`, which is how these roles write files. The header must never contain a date or hostname, or every run reports a change forever. One deliberate exception to `backup:`: the systemd unit written by `base`, because a stray backup file in a unit directory makes systemd log parse warnings on every `daemon-reload`. Everywhere else the backup is inert — sudo, sshd's `Include *.conf`, apt, `sysctl.d` and `modules-load.d` all ignore the `.<pid>.<date>~` suffix.

## Not yet implemented

Argo CD adoption of the Ansible-owned platform components, Alertmanager + ntfy alerts, trusted TLS (Phase 2.75), Tailscale split DNS, `images/` (agent sandbox image), HA control plane (kube-vip). See `docs/PROJECT-PLAN.md` for the roadmap.

<!-- OPENWIKI:START -->

## OpenWiki

This repository uses OpenWiki for recurring code documentation. Start with `openwiki/quickstart.md`, then follow its links to architecture, workflows, domain concepts, operations, integrations, testing guidance, and source maps.

The scheduled OpenWiki GitHub Actions workflow refreshes the repository wiki. Do not hand-edit generated OpenWiki pages unless explicitly asked; prefer updating source code/docs and letting OpenWiki regenerate.

<!-- OPENWIKI:END -->

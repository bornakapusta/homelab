---
status: complete
priority: p2
issue_id: "008"
tags: [code-review, correctness, networking, ansible]
dependencies: []
---

# Neither `kubeadm init` nor the kubelet pins an address — multi-homed WiFi+wired nodes can advertise the wrong IP

## Problem Statement

`roles/control_plane/tasks/main.yml:12-18` runs:

```
kubeadm init --control-plane-endpoint=… --pod-network-cidr=… --node-name=…
```

with no `--apiserver-advertise-address`. `kubeadm` then picks the IP of the
interface holding the default route. Likewise nothing sets the kubelet's
`--node-ip`, so each node self-reports whichever address the kubelet infers.

These nodes are Dell OptiPlex 7050s with **both** onboard Ethernet and WiFi, and
the stated plan is WiFi first, wired later. During the transition — or any time
both interfaces are up — the inferred address may not be the `ansible_host` value
that everything else in the repo is built around:

- `group_vars/all.yml:15` — `node_ips` derives from `ansible_host`
- `roles/hardening/tasks/main.yml:63-67` — ufw trusts exactly those IPs
- `roles/base/tasks/main.yml:19` — `/etc/hosts` maps `control_plane_endpoint` to `hostvars[cp].ansible_host`

If the kubelet advertises the wired IP while ufw only trusts the WiFi IPs, node-to-node
traffic (kubelet 10250, Calico IPIP) is dropped and nodes flap `NotReady`.

## Findings

1. **The failure mode is indistinguishable from the WiFi flapping this repo
   already guards against.** `roles/base/tasks/main.yml:51-54` installs a
   power-save-off unit precisely because node flapping is hard to diagnose. A
   wrong `--node-ip` produces the same symptom from a completely different cause,
   which makes it expensive to chase.
2. **`ansible_host` is the de facto source of truth** across four separate places
   in the repo, but Kubernetes is never told about it. That gap is the bug.
3. **DHCP reservations are planned but not yet set** — `inventory.ini:13-14` has a
   `TODO: confirm these once nodes 2 and 3 are installed` and a reminder to set
   Fritz!Box reservations. Until those exist, addresses can move, and the
   inference gets a second chance to be wrong.
4. **`--apiserver-cert-extra-sans` is also absent.** Certificate SANs will cover
   `control_plane_endpoint` and the inferred node IP. If you later reach the API
   server by an address that was not in the SAN list, TLS fails and the fix
   requires regenerating certs. Cheap to add now.
5. **`--upload-certs` is absent too.** Stage B (`inventory.ini:5-6`) moves node-2
   and node-3 into `[control_plane]`; joining additional control-plane nodes needs
   the certificate key that `--upload-certs` produces. It can be regenerated later
   with `kubeadm init phase upload-certs --upload-certs`, so this is not urgent —
   just worth noting so Stage B is not a surprise.
6. **`--pod-network-cidr` and the Calico patch are consistent** — `pod_cidr` is
   `10.244.0.0/16` (`group_vars/all.yml:32`) and the Calico manifest is patched to
   match with a verification task (`roles/control_plane/tasks/main.yml:89-93`).
   The CIDR side of the networking is well handled; only the node addressing is not.

## Proposed Solutions

### Option A — pin both addresses from `ansible_host` (recommended)

```yaml
# roles/control_plane/tasks/main.yml
- name: Initialise the control plane
  ansible.builtin.command: >
    kubeadm init
    --control-plane-endpoint={{ control_plane_endpoint }}
    --apiserver-advertise-address={{ ansible_host }}
    --apiserver-cert-extra-sans={{ ansible_host }},{{ control_plane_endpoint }}
    --pod-network-cidr={{ pod_cidr }}
    --node-name={{ inventory_hostname }}
    --skip-token-print
  when: not admin_conf.stat.exists
```

And in `kubernetes_node`, before the kubelet is enabled
(`roles/kubernetes_node/tasks/main.yml:171-176`):

```yaml
- name: Pin the kubelet's advertised node IP
  ansible.builtin.copy:
    dest: /etc/default/kubelet
    owner: root
    group: root
    mode: "0644"
    content: "KUBELET_EXTRA_ARGS=--node-ip={{ ansible_host }}\n"
  notify: Restart kubelet
```

This makes `ansible_host` authoritative for Kubernetes too, matching ufw and
`/etc/hosts`. When the nodes move to wired, you change `inventory.ini` and
everything follows from one place.

- **Pros:** single source of truth for addressing; removes a whole class of
  hard-to-diagnose flapping; the extra SANs make future access paths cheap.
- **Cons:** `--node-ip` must be set **before** the node joins, or the change
  requires a kubelet restart and a Node object update; needs a new
  `Restart kubelet` handler in `roles/kubernetes_node/handlers/main.yml`.
  `--apiserver-advertise-address` cannot be changed after `kubeadm init` without a
  reset — so this must land before the first `make cluster`.
- **Effort:** Small. **Risk:** Low if applied before first bootstrap; Medium after.

### Option B — set `--node-ip` only, leave `kubeadm init` alone

- **Pros:** smaller change; fixes the worker-side flapping, which is the more
  likely symptom.
- **Cons:** the API server may still advertise an unexpected address; the SAN gap
  remains.
- **Effort:** Trivial. **Risk:** Low.

### Option C — accept the inference, ensure only one interface is ever up

Disable the onboard NIC in BIOS while on WiFi, and disable WiFi when moving to
wired.

- **Pros:** zero code change; the inference is then unambiguous.
- **Cons:** relies on manual per-machine BIOS state that no playbook records or
  verifies — exactly the kind of undocumented drift this repo exists to eliminate.
  Also makes the WiFi→wired migration a physical, per-node operation with no
  rollback.
- **Effort:** Trivial. **Risk:** Medium.

## Recommended Action

_(fill during triage)_

**Timing note:** `--apiserver-advertise-address` is baked in at `kubeadm init`.
Decide before the first `make cluster`, or plan on a `kubeadm reset`.

## Technical Details

**Affected files:**
- `ansible/roles/control_plane/tasks/main.yml:12-21` — add advertise address + extra SANs
- `ansible/roles/kubernetes_node/tasks/main.yml:171-176` — add `/etc/default/kubelet`
- `ansible/roles/kubernetes_node/handlers/main.yml` — add `Restart kubelet` handler
- `ansible/inventory.ini:13-16` — resolve the `TODO`; set DHCP reservations first
- `CLAUDE.md` — record that `ansible_host` is authoritative for node addressing

## Acceptance Criteria

- [ ] DHCP reservations set in the Fritz!Box for all three nodes; `inventory.ini` TODO removed
- [ ] `kubectl get nodes -o wide` INTERNAL-IP matches `ansible_host` for all three nodes
- [ ] `kubectl -n kube-system get endpoints kubernetes` shows the CP's `ansible_host`
- [ ] `openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text` lists both `control_plane_endpoint` and the CP IP in SANs
- [ ] Nodes stay `Ready` for 24 h with both interfaces physically connected
- [ ] Stage B prerequisite noted: certificate key regeneration via `kubeadm init phase upload-certs`

## Work Log

- 2026-07-26 — RESOLVED in the same session. kubeadm init now passes --apiserver-advertise-address={{ ansible_host }} and --apiserver-cert-extra-sans. kubelet --node-ip pinned via /etc/default/kubelet with a Restart kubelet handler gated on the node having actually joined. Preflight now requires every ansible_host to be a literal IPv4 address, which is what these flags and the ufw src rules need.
- 2026-07-26 — Filed from `/ce-review`. Hardware detail (OptiPlex 7050 has both
  WiFi and Ethernet; WiFi first, wired later) taken from project memory and is
  what makes this more than theoretical.

## Resources

- `ansible/group_vars/all.yml:11-15` — `node_ips` derivation
- `ansible/roles/hardening/tasks/main.yml:60-67` — ufw peer trust based on those IPs
- `ansible/roles/base/tasks/main.yml:51-54` — the existing WiFi-flapping mitigation

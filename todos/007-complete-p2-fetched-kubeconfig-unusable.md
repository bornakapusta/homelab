---
status: complete
priority: p2
issue_id: "007"
tags: [code-review, operations, developer-experience, ansible]
dependencies: []
---

# `make status` will fail: the fetched kubeconfig points at `k8s.lab.example`, which the laptop cannot resolve

## Problem Statement

`roles/control_plane/tasks/main.yml:41-45` fetches `/etc/kubernetes/admin.conf` to
`ansible/kubeconfig`. Because `kubeadm init` was run with
`--control-plane-endpoint={{ control_plane_endpoint }}`
(`roles/control_plane/tasks/main.yml:15`), that kubeconfig contains:

```yaml
server: https://k8s.lab.example:6443
```

`roles/base/tasks/main.yml:15-20` adds `k8s.lab.example` to `/etc/hosts` on **the
nodes**. Nothing adds it to the laptop. So `make status` (`Makefile:21-23`) fails
with a DNS resolution error on the very first attempt, immediately after a
successful `make all`.

This is guaranteed, not conditional — `k8s.lab.example` is in a reserved TLD and
cannot resolve publicly by design.

## Findings

1. **Already half-documented, not handled.** `group_vars/all.yml:22-23` says
   "add it to `/etc/hosts` on your laptop + nodes if you have no local DNS yet",
   and the playbook does the nodes half. The laptop half is left as an unwritten
   manual step, and `make status` is presented as ready-to-use.
2. **The name-based endpoint is the right call.** The comment at
   `roles/control_plane/tasks/main.yml:9-11` is correct: putting a DNS name rather
   than an IP in the certificate SANs is what allows extra control-plane nodes
   later without regenerating certs. Do **not** "fix" this by switching to an IP.
3. **`.example` is reserved (RFC 2606/6761)**, so it will never resolve and never
   collide. Good choice for a placeholder — but it means there is no fallback path.
4. **`make status` is the first thing you run after `make all`**, so this is the
   first impression of the whole repo, and it looks like the cluster is broken when
   it is fine.
5. **The permission fix-up is correct.**
   `roles/control_plane/tasks/main.yml:47-52` chmods the fetched file to `0600` and
   `.gitignore:2` excludes `kubeconfig`. No credential-leak issue here.

## Proposed Solutions

### Option A — `make hosts` helper + a preflight check in `make status` (recommended)

Add to the `Makefile`:

```make
## print the /etc/hosts line your laptop needs
hosts:
	@echo "Add this to /etc/hosts on your laptop (needs sudo):"
	@cd $(ANSIBLE_DIR) && ansible-inventory --list 2>/dev/null | \
	  python3 -c 'import json,sys; d=json.load(sys.stdin); \
	    print(d["_meta"]["hostvars"]["node-1"]["ansible_host"], "k8s.lab.example")'

status:
	@getent hosts k8s.lab.example >/dev/null 2>&1 || \
	  { echo "k8s.lab.example does not resolve — run 'make hosts' first"; exit 1; }
	KUBECONFIG=$(ANSIBLE_DIR)/kubeconfig kubectl get nodes -o wide
	KUBECONFIG=$(ANSIBLE_DIR)/kubeconfig kubectl get pods -A
```

(`getent` is Linux-only; on macOS use `dscacheutil -q host -a name k8s.lab.example`
or simply `ping -c1 -t1`. Pick one and note the platform.)

- **Pros:** keeps the name-based endpoint intact; fails with an actionable message
  instead of an opaque DNS error; does not touch the laptop's `/etc/hosts` without
  consent.
- **Cons:** still one manual `sudo` step, once, on the laptop.
- **Effort:** Small. **Risk:** Low.

### Option B — rewrite the fetched kubeconfig's server to the CP node's IP

After `fetch`, run a `replace` on the local copy swapping
`https://k8s.lab.example:6443` for `https://<cp ip>:6443`.

- **Pros:** `make status` works with zero manual setup.
- **Cons:** the CP node's certificate SANs include the *name*, not necessarily the
  IP — kubeadm does add the node IP to the SAN list by default, so this generally
  works, but it silently breaks the moment you move to a kube-vip VIP in Stage B
  (`inventory.ini:5-6`). It also means the laptop's kubeconfig and the nodes'
  kubeconfigs disagree, which is confusing during incidents.
- **Effort:** Small. **Risk:** Medium.

### Option C — real local DNS (Fritz!Box static hostname, or dnsmasq)

`inventory.ini:14` already tells you to set DHCP reservations in the Fritz!Box.
Some Fritz!Box firmware lets you assign a local hostname per reservation, resolvable
as `<name>.fritz.box`.

- **Pros:** solves it properly for every device on the LAN, permanently; the right
  end state, and a prerequisite for Stage B HA anyway.
- **Cons:** depends on router capability; `k8s.lab.example` would need to become
  something the router can actually serve, which means re-running `kubeadm init`
  (the endpoint is baked into the certs) — so this is cheap **now**, before the
  first `make cluster`, and expensive later.
- **Effort:** Medium. **Risk:** Low — but do it before the first `kubeadm init`, not after.

## Recommended Action

_(fill during triage)_

**Timing note for triage:** Option C is materially cheaper before the first
`make cluster` than after, because `control_plane_endpoint` is written into the
certificate SANs. If local DNS is where you want to end up, decide now.

## Technical Details

**Affected files:**
- `Makefile:20-23` — `status` target, add preflight
- `Makefile` — new `hosts` target
- `ansible/group_vars/all.yml:22-26` — `control_plane_endpoint` and its comment
- `ansible/roles/control_plane/tasks/main.yml:41-52` — fetch + chmod
- `README.md` / `CLAUDE.md` — document the laptop `/etc/hosts` step in the setup flow

## Acceptance Criteria

- [ ] `make status` either works, or fails with a message naming the exact fix
- [ ] The `/etc/hosts` line (or DNS record) is documented in `README.md` as a numbered setup step
- [ ] `control_plane_endpoint` remains a DNS name, not an IP (Stage B compatibility)
- [ ] Fetched `ansible/kubeconfig` is mode `0600` and gitignored (already true — regression check)
- [ ] The chosen approach is noted in `CLAUDE.md` so it is not re-litigated

## Work Log

- 2026-07-26 — RESOLVED in the same session. Added `make hosts` (prints the exact /etc/hosts line, reading the IP and endpoint from inventory.ini and group_vars rather than duplicating them) and a resolution preflight in `make status` that fails with a pointer instead of an opaque DNS error. control_plane_endpoint left as a DNS name.
- 2026-07-26 — Filed from `/ce-review`. Cannot verify by running: `kubectl` and
  `ansible` are not installed on this machine and no cluster exists yet.

## Resources

- `ansible/roles/base/tasks/main.yml:15-20` — the node-side `/etc/hosts` task, which is the pattern to mirror
- `ansible/group_vars/all.yml:22-26` — endpoint definition and existing caveat

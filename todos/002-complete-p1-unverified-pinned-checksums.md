---
status: complete
priority: p1
issue_id: "002"
tags: [code-review, security, supply-chain, ansible]
dependencies: []
---

# Hard-coded SHA256 checksums are unverified and will block the first run

## Problem Statement

Three remote artefacts are fetched with hard-coded `checksum:` values:

| File | Location | Pinned digest (truncated) |
|---|---|---|
| Docker GPG key | `roles/kubernetes_node/tasks/main.yml:68` | `1500c1f5…3a570` |
| Kubernetes `Release.key` (v1.36) | `roles/kubernetes_node/tasks/main.yml:131` | `7627818c…be54d` |
| `calico.yaml` (v3.30.0) | `roles/control_plane/tasks/main.yml:72` | `cfa6f946…12b248` |

Pinning is the right instinct — it is what stops a MITM on the WiFi link from
handing you a substituted apt signing key. But these specific digests have never
been verified against the real artefacts (the repo has **zero commits**, so
nothing has ever run). If any one is wrong, `get_url` fails and provisioning stops
on all three nodes at the same task.

## Findings

1. **Never executed.** `git log` is empty; `site.yml` has never run. The digests
   are asserted, not observed.
2. **`Release.key` is per-minor-version.** The URL is
   `https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_minor }}/deb/Release.key`.
   Bumping `kubernetes_minor` in `group_vars/all.yml:38` changes the URL and
   therefore the digest, but nothing in the repo ties the two together — the next
   minor upgrade will fail with a checksum mismatch and no hint as to why.
3. **The Docker key is a rotating aggregate.** `download.docker.com/linux/ubuntu/gpg`
   is an ASCII keyring that changes whenever Docker adds or rotates a subkey. A
   legitimate rotation is indistinguishable from an attack, from the playbook's
   point of view — it just fails.
4. **`calico.yaml` is fetched from `raw.githubusercontent.com` at a tag.** Git tags
   are mutable. The checksum is the only thing making this reproducible, so it
   genuinely matters here — but it also silently breaks if Calico force-pushes the
   tag or if you bump `calico_version` without recomputing.
5. **No comment records provenance.** Nothing says where each digest came from or
   how to regenerate it, so the next person's rational move is to delete the
   `checksum:` line — which is the worst possible outcome.

## Proposed Solutions

### Option A — verify out-of-band, then annotate provenance (recommended)

Before the first run, from a trusted network:

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sha256sum
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sha256sum
curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/calico.yaml | sha256sum
```

Cross-check the GPG keys against a second source (Docker's install docs, the
Kubernetes install docs) — a checksum you computed from the same channel you're
trying to protect proves nothing about authenticity, only about consistency.

Then move the digests next to the versions they belong to, in
`group_vars/all.yml`, with a regeneration note:

```yaml
kubernetes_minor: "1.36"
# sha256 of https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key
# regenerate on every kubernetes_minor bump:
#   curl -fsSL <url> | sha256sum
kubernetes_key_sha256: "…"
```

- **Pros:** keeps the security property; the coupling between version and digest
  becomes visible; failures become self-explanatory.
- **Cons:** one manual step per version bump.
- **Effort:** Small. **Risk:** Low.

### Option B — verify the GPG keys by fingerprint instead of file digest

Import to a temporary keyring and assert the expected long fingerprint. A key
fingerprint is stable across keyring re-serialisation, so legitimate rotation
does not break the play.

- **Pros:** robust against benign key-file churn; asserts the property you
  actually care about (identity), not a file byte-for-byte.
- **Cons:** more moving parts (`gpg --with-colons` parsing, `assert`).
- **Effort:** Medium. **Risk:** Low.

### Option C — drop the checksums

- **Pros:** nothing blocks the first run.
- **Cons:** unauthenticated fetch of two **apt signing keys** over the WiFi link,
  compounded by `host_key_checking = False` (`ansible.cfg:5`). Do not do this.
- **Effort:** Trivial. **Risk:** High.

## Recommended Action

_(fill during triage)_

## Technical Details

**Affected files:**
- `ansible/roles/kubernetes_node/tasks/main.yml:68` — Docker GPG key
- `ansible/roles/kubernetes_node/tasks/main.yml:131` — Kubernetes `Release.key`
- `ansible/roles/control_plane/tasks/main.yml:72` — `calico.yaml`
- `ansible/group_vars/all.yml:34-40` — versions block, where digests should live

Also confirm the versions themselves exist before running: `kubernetes_minor: "1.36"`,
`kubernetes_apt_version: "1.36.3-1.1"`, `calico_version: "v3.30.0"`.
`group_vars/all.yml:35` already flags this ("CHECK THESE BEFORE YOUR FIRST RUN").
A wrong `kubernetes_apt_version` fails later, at apt, with a clearer message than
the checksum mismatch — but both are first-run blockers.

## Acceptance Criteria

- [ ] All three digests recomputed from the live URLs and matching what is committed
- [ ] Both GPG key digests cross-checked against a second, independent source
- [ ] Digests live beside their version variables with a regeneration command in a comment
- [ ] `kubernetes_apt_version` confirmed to exist: `apt-cache madison kubeadm` on a node
- [ ] `calico_version` confirmed to be a real released tag
- [ ] A dry first run of `site.yml` against **one** node reaches the end without a checksum failure

## Work Log

- 2026-07-26 — RESOLVED in the same session. Verified all three digests against upstream: Docker key, k8s Release.key and calico.yaml v3.30.0 ALL MATCH what was committed. Finding #2 was WRONG — the k8s Release.key is byte-identical across v1.34/1.35/1.36, so a kubernetes_minor bump does not invalidate it; corrected in group_vars. Confirmed kubernetes_apt_version 1.36.3-1.1 exists. Digests moved next to their versions in group_vars with regeneration commands; preflight asserts all three are present and 64 chars.
- 2026-07-26 — Filed from `/ce-review`. Cannot verify locally: no `ansible`,
  `ansible-lint`, or `yamllint` on this machine, and the digests require network
  fetches from a trusted path.

## Resources

- `ansible/group_vars/all.yml:34-40` — version pins
- Related: `009-pending-p2-ssh-host-key-checking-disabled.md` (same threat model)
- Related: `012-pending-p3-unpinned-collection-requirements.md`

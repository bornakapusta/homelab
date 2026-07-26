---
status: complete
priority: p3
issue_id: "015"
tags: [code-review, tooling, quality, ansible]
dependencies: []
---

# No lint, no syntax check, no CI — and Ansible is not installed on the controller

## Problem Statement

The repo has 23 YAML files across 5 roles and 2 playbooks, zero commits, and has
never been executed or validated. On this controller:

```
$ which ansible-playbook ansible-lint yamllint
ansible-lint not found
yamllint not found
ansible-playbook not found
```

So the first time any of this YAML is parsed will be the first time it is run
against real machines. For a repo whose entire purpose is to configure three
machines reproducibly, that ordering is backwards — and several findings in this
review (`002`, `012`) could not be verified precisely because the tooling is absent.

## Findings

1. **A syntax check is free and catches a whole class of error.**
   `ansible-playbook --syntax-check site.yml cluster.yml` parses every role and
   task file without touching a host. That alone would validate the 23 files.
2. **`ansible-lint` would have flagged real items from this review**, notably the
   `no_log` / `changed_when` patterns (`003`, `014`) and the unescaped
   `regexp` interpolation (`013`). It also enforces the FQCN convention this repo
   already follows consistently — worth locking in before it drifts.
3. **`Makefile` has no `deps` or `check` target.** `CLAUDE.md` documents
   `ansible-galaxy collection install -r ansible/requirements.yml` under
   Conventions, but it is not wired into the Makefile alongside `ping` / `nodes` /
   `cluster`, so it is a step you have to remember.
4. **CI is arguably overkill here, and arguably not.** This is a 3-node personal
   homelab; a GitHub Actions workflow is more ceremony than the project needs. But
   `--syntax-check` + `ansible-lint` in a pre-commit hook or a `make check` target
   costs nothing per run and pays for itself the first time it catches a typo before
   it reaches a node.
5. **A dry run against one node is the real missing safety step.** Before the first
   `make nodes` against all three, running `site.yml --limit node-1 --check --diff`
   would be ideal — except `--check` currently errors (see
   `014-pending-p3-idempotency-changed-when-noise.md` finding: `containerd config default`
   does not run in check mode, leaving `containerd_default_config.stdout` undefined).
   So `--limit node-1` for real, with `serial: 1` from
   `006-pending-p2-serial-rollout-blast-radius.md`, is the practical version.
6. **Third-party dependency:** nothing pins `ansible-lint` either. If it lands,
   pin it in the same place as the collections.

## Proposed Solutions

### Option A — `make check` + `make deps`, no CI (recommended)

```make
.PHONY: deps check ping nodes cluster all status reset-help

## install required Ansible collections
deps:
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

## parse + lint everything without touching a node
check:
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check site.yml cluster.yml
	cd $(ANSIBLE_DIR) && ansible-lint
```

Plus a minimal `.ansible-lint` so the ruleset is explicit rather than
version-dependent:

```yaml
---
profile: production
exclude_paths:
  - ansible/kubeconfig
skip_list:
  - fqcn[action-core]   # only if it proves noisy; the repo already uses FQCNs
```

Prerequisite: install the tooling on the controller
(`pipx install ansible-core ansible-lint` or `brew install ansible ansible-lint`),
then `make deps`.

- **Pros:** catches parse and convention errors before they reach a node; two
  Makefile targets; discoverable next to the existing ones; `make deps` removes a
  remembered step.
- **Cons:** you have to actually run `make check`; `ansible-lint --profile production`
  will likely surface a batch of findings on first run that need triaging or skipping.
- **Effort:** Small. **Risk:** Low.

### Option B — Option A plus a pre-commit hook

Add `.pre-commit-config.yaml` running `yamllint` and `ansible-lint` on changed files.

- **Pros:** cannot be forgotten; keeps the repo clean by construction.
- **Cons:** another tool to install and keep working; pre-commit hooks get bypassed
  with `--no-verify` under time pressure anyway.
- **Effort:** Small. **Risk:** Low.

### Option C — GitHub Actions workflow

Run `--syntax-check` and `ansible-lint` on push.

- **Pros:** runs regardless of local tooling; visible history of green/red.
- **Cons:** meaningful ceremony for a single-operator homelab; the repo has no
  remote configured yet (`git status` shows a local `master` with the main branch
  nominally `main`), so this is premature.
- **Effort:** Small. **Risk:** Low.

## Recommended Action

_(fill during triage)_

**Do this before the first `make nodes`, not after.** A `--syntax-check` run right
now is the cheapest possible validation of 23 never-parsed files, and several other
todos in this batch (`002`, `012`) are blocked on having Ansible installed at all.

## Technical Details

**Affected files:**
- `Makefile:1` — extend `.PHONY`; add `deps` and `check` targets
- `.ansible-lint` — new file
- `ansible/requirements.yml` — see `012-pending-p3-unpinned-collection-requirements.md`
- `CLAUDE.md` — add `make check` / `make deps` to the Commands section
- `.gitignore` — add `.ansible-lint-cache/` if lint is added

**Branch note:** the working branch is `master` while `CLAUDE.md`/repo convention
refers to `main`. Worth reconciling before the first commit, since the whole tree is
currently staged-but-uncommitted.

## Acceptance Criteria

- [ ] `ansible-core` and `ansible-lint` installed on the controller
- [ ] `make deps` installs collections from `requirements.yml`
- [ ] `make check` passes: `--syntax-check` clean on both playbooks
- [ ] `ansible-lint` passes, or every skipped rule is listed in `.ansible-lint` with a reason
- [ ] `make check` documented in `CLAUDE.md` Commands
- [ ] Both playbooks syntax-checked **before** the first real `make nodes`

## Work Log

- 2026-07-26 — RESOLVED in the same session. Added `make check` (--syntax-check + ansible-lint) and `make deps`, plus .ansible-lint. Installed ansible-core 2.21.2 + ansible-lint 26.6.0 in a throwaway venv and actually ran them: the tree now passes ansible-lint's *production* profile (stricter than the moderate target), 35 files, 0 failures. Fixed what it found: replaced fake galaxy_info metadata in all 7 role meta files with a plain dependencies: [] (these roles are never published, so the Galaxy schema does not apply). Skipped only var-naming[no-role-prefix], with a documented reason.
- 2026-07-26 — Filed from `/ce-review`. Attempted `ansible-playbook --syntax-check`
  and `ansible-lint` during the review; both unavailable, so all findings in this
  batch are from reading, not execution. That is itself the finding.

## Resources

- `Makefile` — existing target style to match
- `CLAUDE.md` — Commands section
- Related: `012-pending-p3-unpinned-collection-requirements.md`
- Related: `014-pending-p3-idempotency-changed-when-noise.md` — why `--check` mode does not currently work

# base

Baseline OS configuration, identical on every node: hostname, `/etc/hosts`,
timezone, chrony, apt upgrade, base packages, WiFi power-save off, hardware
sensor modules, and pending-reboot reporting.

**Unit of automation:** one machine's OS baseline. **Outcome:** a patched,
time-synchronised node that can resolve the control-plane endpoint.

> **This role is a patch event.** It runs `apt upgrade`, so every application may
> pull a kernel. Nothing reboots automatically — on a cluster you drain first, by
> hand, one node at a time. A pending reboot is reported at the end of the run.

| Property | Value |
|---|---|
| Idempotent | **True**, with one caveat below |
| Atomic | **False** — a failure mid-run leaves earlier tasks applied |
| Check mode | Supported |

**Idempotency caveat:** `apt upgrade` is idempotent in the sense that a converged
node reports no change, but it is not *reproducible* — the packages it installs
depend on when you run it. Two nodes provisioned weeks apart will differ. This is
why the Kubernetes and containerd packages are pinned and held by the
`kubernetes_node` role instead of being left to this one.

## Arguments

Declared and validated in [`meta/argument_specs.yml`](meta/argument_specs.yml).

Required: `timezone`, `control_plane_endpoint`, `control_plane_host`.
Optional: `base_packages`, `base_sensor_modules`.

## Hardware sensors

`base_sensor_modules` (default: `coretemp`) is written to
`/etc/modules-load.d/sensors.conf` and modprobed in the same run, so the modules
are loaded now *and* after the next reboot. Their only job is to populate
`/sys/class/hwmon`, which is where `node_exporter`'s hwmon collector reads
`node_hwmon_temp_celsius` from.

This lives here rather than in `kubernetes_node` on purpose: sensing the hardware
is a property of the machine, not a kubeadm prerequisite.

`lm-sensors` is installed for *human* verification only — nothing at runtime
shells out to `sensors`. Verify on a node with:

```bash
sensors                                    # expect coretemp-isa-0000, Package id 0
grep . /sys/class/hwmon/hwmon*/name        # expect coretemp
cat /sys/class/hwmon/hwmon*/temp1_input    # millidegrees, e.g. 42000
```

If `/sys/class/hwmon` is empty after a run, the temperature metrics are not
achievable on that hardware and `coretemp` is the wrong module for it —
`dell-smm-hwmon` (possibly with `force=1`) is the next thing to try, but it is
unreliable across Dell desktop models and is deliberately not a default.

## Rollback

No automatic rollback. Per-item recovery:

| Change | How to undo |
|---|---|
| Hostname | `sudo hostnamectl set-hostname <old>` |
| `/etc/hosts` entries | Managed by `lineinfile`; edit or delete the line |
| WiFi power-save unit | `sudo systemctl disable --now wifi-no-powersave.service` then delete `/etc/systemd/system/wifi-no-powersave.service` |
| Hardware sensor modules | `sudo rm /etc/modules-load.d/sensors.conf` then `sudo modprobe -r coretemp`. The `modprobe -r` may fail with `Module coretemp is in use` if something is reading it — harmless, the file removal is what stops it loading at boot. |
| `apt upgrade` | Not reversible in practice. Restore from a snapshot if you need the old package set. |

Files this role **replaces** wholesale rather than edits:
`/etc/systemd/system/wifi-no-powersave.service`, `/etc/modules-load.d/sensors.conf`.
Every file it writes carries an `Ansible managed` header.

## Usage

```yaml
- name: Configure all cluster nodes
  hosts: k8s_cluster
  roles:
    - role: base
      tags: [base]
```

# metallb

Installs a reproducible MetalLB release on the live kubeadm cluster. The role
runs kubectl on the Ansible controller using the admin kubeconfig fetched by
`control_plane`; it does not install packages on the nodes directly.

This homelab uses **native Layer 2 mode**. A speaker runs on every node and one
speaker answers ARP requests for each LoadBalancer address. FRR-K8s and FRR are
explicitly disabled because no BGP router or BFD session is needed on a single
home LAN.

## Safety and supply-chain controls

- The official native manifest is downloaded from the versioned release URL and
  checked against `metallb_manifest_sha256` before kubectl sees it.
- Controller and speaker use immutable multi-architecture OCI index digests.
- The namespace carries the privileged Pod Security labels required by the
  speaker's networking capabilities.
- IPVS kube-proxy is rejected unless `strictARP` is enabled.
- An address pool cannot be created until
  `metallb_address_pool_confirmed=true`. This is an explicit acknowledgement
  that the range is outside the router's DHCP pool and every reservation.

## Arguments

The enforced interface lives in `meta/argument_specs.yml`:

| Variable | Required | Purpose |
|---|---:|---|
| `metallb_version` | yes | Exact upstream release used in the manifest URL and image references |
| `metallb_manifest_sha256` | yes | SHA-256 of the official native manifest |
| `metallb_controller_image_sha256` | yes | Multi-architecture controller image digest |
| `metallb_speaker_image_sha256` | yes | Multi-architecture speaker image digest |
| `metallb_address_pool_state` | yes | Whether the role-owned pool and advertisement are `present` or `absent` |
| `metallb_address_pool_confirmed` | yes | Explicit acknowledgement that the range is collision-free |
| `metallb_address_ranges` | yes | IPv4 CIDRs or ascending first-last ranges used for LoadBalancer Services |
| `metallb_pool_name` | no | Role-owned IPAddressPool name; defaults to `lan-pool` |
| `metallb_l2_advertisement_name` | no | Role-owned L2Advertisement name; defaults to `lan` |
| `metallb_kubeconfig` | no | Controller kubeconfig path; defaults to `{{ playbook_dir }}/kubeconfig` |

The upstream manifest is fixed to its required `metallb-system` namespace; the
namespace is intentionally not configurable.

## Address-pool rollout

On a new network, start deliberately inert:

```yaml
metallb_address_pool_state: absent
metallb_address_pool_confirmed: false
metallb_address_ranges: []
```

After checking the router's DHCP range, choose an unused range on the same LAN
and change all three values together. This homelab's DHCP pool is
`192.168.178.20-192.168.178.200`, so its confirmed configuration is:

```yaml
metallb_address_pool_state: present
metallb_address_pool_confirmed: true
metallb_address_ranges:
  - 192.168.178.240-192.168.178.250
```

Run `make platform` after editing. Re-runs reconcile the native manifest and the
role-owned `lan-pool` / `lan` resources.

## Rollback

Set `metallb_address_pool_state: absent`, clear `metallb_address_ranges`, and run
`make platform` to remove the role-owned pool and advertisement while leaving
MetalLB healthy but idle. The role refuses this change while Services still use
the pool, because silently withdrawing an allocated address would interrupt
ingress traffic; delete or deliberately reassign those Services first.

To remove MetalLB itself, first disable the pool as above. Then, from the
repository root, download the configured manifest and verify the configured
checksum before using it as the deletion inventory:

```bash
(
  set -eu
  metallb_release="$(awk -F '"' '/^metallb_version:/ { print $2 }' ansible/group_vars/all.yml)"
  metallb_manifest_checksum="$(awk -F '"' '/^metallb_manifest_sha256:/ { print $2 }' ansible/group_vars/all.yml)"
  metallb_rollback_dir="$(mktemp -d)"
  trap 'rm -r "${metallb_rollback_dir}"' EXIT

  curl --connect-timeout 10 --max-time 60 -fsSL \
    "https://raw.githubusercontent.com/metallb/metallb/v${metallb_release}/config/manifests/metallb-native.yaml" \
    --output "${metallb_rollback_dir}/metallb-native.yml"
  printf '%s  %s\n' "${metallb_manifest_checksum}" "${metallb_rollback_dir}/metallb-native.yml" \
    | shasum -a 256 --check
  kubectl --request-timeout=30s --kubeconfig ansible/kubeconfig delete \
    --timeout=120s \
    --filename "${metallb_rollback_dir}/metallb-native.yml"
)
```

The later Argo CD phase should adopt this release and its declarative values;
after adoption, do not let both Argo CD and this role reconcile the same objects.

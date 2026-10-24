# rhsb-2026-012-crio-hook

Temporary mitigation for [RHSB-2026-012](https://access.redhat.com/security/vulnerabilities/RHSB-2026-012)
(eMudhra CA compromise) on OpenShift Container Platform clusters that cannot be updated yet.

> **Note:** This is not an official Red Hat project and is not supported by Red Hat.
> The supported fix is the patched `ca-certificates` package and the OpenShift z-stream
> that ships it.

## Overview

Each container image includes its own CA trust store. Updating the node does not change
the trust store inside running workloads, and rebuilding every image takes time.

This project installs a CRI-O OCI hook on each node. When a container is created, the hook
removes the compromised root certificates from that container's trust store. Container
images, pod specifications and node configuration are not modified.

![How it works](docs/how-it-works.png)

Certificates removed:

| Root CA | SHA-256 fingerprint |
|---|---|
| emSign Root TLS CA - G3 | `7DD78D5F...2746ED8D` |
| emSign ECC Root CA - G3 | `86A1ECBA...A36BBE6B` |
| emSign Root CS CA - G3 | `F2EDAAFF...DABA34A5` |
| AAA Certificate Services | `D7A7A0FB...EA699EF4` |

Supported trust stores: RHEL and UBI, Debian and Ubuntu, Alpine, SUSE, the OpenSSL hash
directory, Python `certifi`, and Java `cacerts` (replaced with the copy from a patched
UBI 9 image).

## Prerequisites

- OpenShift Container Platform 4.x with CRI-O
- `cluster-admin` access
- `oc` and `podman` on the workstation that renders the manifest

No additional images are required. The DaemonSet uses the `cli` image from the cluster's
release payload, which is already available in disconnected mirror registries.

## Install

```bash
make deploy IMAGE=$(oc adm release info --image-for=cli)
```

The hook applies to containers created after installation. Restart workloads that make
outbound TLS connections.

## Verify

```bash
make status
```

Each line in the log shows a container ID and the trust store files that were changed.
To test locally before you install, run `make test` and `make fuzz`.

## Uninstall

```bash
make undeploy
```

Uninstall after the cluster is updated to the fixed z-stream and workload images are
rebuilt on the current UBI. After that, the hook makes no changes.

## Considerations

| Benefit | Limitation |
|---|---|
| No image rebuild or pod spec change | Applies only to containers created after install |
| No MachineConfig, node reboot or CRI-O restart | Does not change CA lists compiled into binaries (Node.js, Rust `webpki-roots`, some Go images) |
| No new images to mirror | Requires a privileged DaemonSet |
| Keeps internal and custom CAs | Custom OCI hooks are not a supported OpenShift configuration |
| Removed with `make undeploy`; hook files live in tmpfs | After a node reboot, containers that start before the DaemonSet pod (about 50 seconds) are not cleaned |

The cluster network operator builds the cluster-wide trusted CA bundle from its own
container. When it restarts with the hook installed, the injected `trusted-ca` ConfigMaps
also lose the compromised roots, and operators that watch them restart once.

## Testing

| Test | Result |
|---|---|
| `make fuzz`: 1000 random container layouts | Hook always exits 0, never writes outside the container, keeps every other certificate |
| `make test`: podman, UBI 9 before the fix | Connection to a site that chains to a compromised root fails; other sites connect |
| `hack/test-openshift.sh` on OpenShift 4.20.27 (AWS, 3 control plane, 3 workers) | UBI 9, Debian Python and Java 21 blocked; Node.js 20 not blocked (built-in CA list) |
| OpenShift conformance suite, before and after install | Same result: 7 failures before, 7 after, none caused by the hook |
| Restart of all 96 platform workloads | No crash loops, all cluster operators available |

Details are in [docs/validation.md](docs/validation.md).

## Related mitigations

- Update `ca-certificates` on the mirror host that runs `oc-mirror`. A reboot is not required.
- If the egress proxy inspects TLS, remove the same roots from the proxy trust store.

## License

Apache License 2.0. See [LICENSE](LICENSE).

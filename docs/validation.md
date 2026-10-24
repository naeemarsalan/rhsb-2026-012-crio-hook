# Validation

Results from 2026-10-24.

## Environment

- OpenShift 4.20.27 on AWS (us-east-1): 3 control plane nodes (m6i.xlarge), 3 workers (m6i.2xlarge)
- OVN-Kubernetes, SELinux enforcing
- This release does not include the fixed `ca-certificates` package

## Scenario test

`hack/test-openshift.sh` runs one pod per case with the `restricted-v2` SCC. Each pod connects to
a site that chains to a compromised root and to quay.io.

| Case | Without hook | With hook | After `make undeploy` |
|---|---|---|---|
| UBI 9 before the fix | connects | **blocked** | connects |
| UBI 9 before the fix, read-only root filesystem | connects | **blocked** | connects |
| UBI 9 latest (fixed) | blocked | blocked | blocked |
| Debian, Python 3.11 | connects | **blocked** | connects |
| UBI 9, OpenJDK 21 | connects | **blocked** | connects |
| Node.js 20 | connects | connects | connects |

quay.io connected in every case. Node.js uses a CA list compiled into the binary, which the
hook cannot change.

## Conformance

`openshift-tests run openshift/conformance/parallel`, once before install and once after.

| Run | Passed | Failed | Skipped | Duration |
|---|---|---|---|---|
| Without hook | 1732 | 7 | 1897 | 1h40m |
| With hook | 1734 | 7 | 1897 | 1h43m |

Seven test names failed in both runs (subscription content builds, which need an entitlement,
and router tests). Two failed only in the run with the hook:

- `ResourceQuota ... image-tags`: an image import timeout; it passed on retry.
- `Alerts shouldn't exceed the series limit`: 794 series against a limit of 780, caused by the
  restart of all platform workloads before the run.

Four router and service tests failed only in the run without the hook.

## Other checks

| Check | Result |
|---|---|
| Install | DaemonSet ready on 6 nodes in 21 seconds; no reboot, no CRI-O restart |
| Restart of 96 platform workloads (481 containers) | No crash loops; all cluster operators available |
| SELinux | No AVC denials from the hook |
| Pod start time (40 pods, cached image) | 0.57 seconds average with the hook, 0.50 seconds without |
| Node reboot | Hook reinstalled 52 seconds after boot; 36 node-level platform containers started before it |
| `make undeploy` | Hook config and files removed from every node in under 10 seconds |
| `make fuzz` (1000 random layouts) | Always exits 0; no writes outside the container; no other certificate removed |

## Trusted CA bundle

The cluster network operator builds the cluster-wide trusted CA bundle
(`openshift-config-managed/trusted-ca-bundle`) from its own container. After it restarted with
the hook installed, the bundle and the 24 injected `trusted-ca` ConfigMaps no longer contained
the compromised roots. The image registry and marketplace operators restarted once, which they
do whenever their CA bundle changes. After `make undeploy`, the bundle changes back the next time
the network operator restarts.

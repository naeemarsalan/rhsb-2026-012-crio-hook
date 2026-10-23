#!/bin/bash
# Renders rendered/rhsb-2026-012-hook.yaml (Namespace, SA, SCC binding, ConfigMap, DaemonSet).
#
#   make manifests IMAGE=$(oc adm release info --image-for=cli)
#
# IMAGE      any image with bash + coreutils already in your mirror; the release's cli
#            image always is. Defaults to a placeholder you must replace.
# CACERTS    patched Java keystore to hand to containers. If unset, it is extracted
#            (podman) from a fixed UBI 9 image, FIXED_UBI.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=${IMAGE:-REPLACE_WITH_oc_adm_release_info_--image-for=cli}
# ubi9 9.8-1792742206 (2026-10-23): ca-certificates-2026.2.92_v9.0.319-90.3.el9_8
FIXED_UBI=${FIXED_UBI:-registry.access.redhat.com/ubi9/ubi@sha256:217dd5692d369799d34d09ffb6f5f3404efebc7900834490fdf9ae92fd6721d4}
OUT=rendered/rhsb-2026-012-hook.yaml
mkdir -p rendered
if [ -z "${CACERTS:-}" ]; then
  CACERTS=rendered/cacerts
  podman run --rm "$FIXED_UBI" cat /etc/pki/ca-trust/extracted/java/cacerts > "$CACERTS"
fi
ind() { sed 's/^/    /'; }
{
cat <<Y
apiVersion: v1
kind: Namespace
metadata:
  name: rhsb-2026-012
  labels:
    pod-security.kubernetes.io/enforce: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hook-installer
  namespace: rhsb-2026-012
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hook-installer-privileged
  namespace: rhsb-2026-012
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
- kind: ServiceAccount
  name: hook-installer
  namespace: rhsb-2026-012
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hook
  namespace: rhsb-2026-012
data:
  rhsb-2026-012-scrub: |
$(ind < hook/rhsb-2026-012-scrub)
  rhsb-2026-012.json: |
    {"version":"1.0.0","hook":{"path":"/usr/bin/bash","args":["bash","/run/rhsb-2026-012/rhsb-2026-012-scrub"],"env":["RHSB_LOG=/run/rhsb-2026-012/hook.log","RHSB_JAVA_CACERTS=/run/rhsb-2026-012/cacerts"]},"when":{"always":true},"stages":["prestart"]}
binaryData:
  cacerts: $(base64 -w0 "$CACERTS")
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hook-installer
  namespace: rhsb-2026-012
spec:
  selector:
    matchLabels: {app: rhsb-2026-012-hook}
  template:
    metadata:
      labels: {app: rhsb-2026-012-hook}
    spec:
      serviceAccountName: hook-installer
      priorityClassName: system-node-critical
      tolerations: [{operator: Exists}]
      terminationGracePeriodSeconds: 10
      containers:
      - name: install
        image: $IMAGE
        securityContext: {privileged: true}
        resources: {requests: {cpu: 1m, memory: 8Mi}}
        command: [/bin/bash, -c]
        args:
        - |
          set -e
          # The hook lives in tmpfs (/run): no MachineConfig, no reboot, gone on next node reboot.
          install -d -m 755 /host-run/rhsb-2026-012
          install -m 755 /hook/rhsb-2026-012-scrub /host-run/rhsb-2026-012/rhsb-2026-012-scrub
          install -m 644 /hook/cacerts /host-run/rhsb-2026-012/cacerts
          install -m 644 /hook/rhsb-2026-012.json /host-run/containers/oci/hooks.d/rhsb-2026-012.json
          echo "hook installed on \$NODE"
          # Uninstall when the DaemonSet is deleted (oc delete -f ... is the rollback)
          trap 'rm -f /host-run/containers/oci/hooks.d/rhsb-2026-012.json; echo "hook removed"; exit 0' TERM
          tail -F /host-run/rhsb-2026-012/hook.log 2>/dev/null & wait
        env:
        - name: NODE
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        volumeMounts:
        - {name: hook, mountPath: /hook}
        - {name: run, mountPath: /host-run}
      volumes:
      - name: hook
        configMap: {name: hook}
      - name: run
        hostPath: {path: /run, type: Directory}
Y
} > "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"

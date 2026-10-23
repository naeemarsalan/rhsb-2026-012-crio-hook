#!/bin/bash
# Local proof with podman: same image, without and with the hook.
# Test sites by eMudhra's G3B chains (live as of 2026-10-23):
#   "200" = connected (exposed), "rc=60" = verify failed (protected)
set -u
cd "$(dirname "$0")/.."
HOOKS=$(mktemp -d); LOG=$HOOKS/hook.log
CACERTS=${CACERTS:-rendered/cacerts}
[ -f "$CACERTS" ] || { mkdir -p rendered; podman run --rm registry.access.redhat.com/ubi9/ubi@sha256:217dd5692d369799d34d09ffb6f5f3404efebc7900834490fdf9ae92fd6721d4 \
  cat /etc/pki/ca-trust/extracted/java/cacerts > "$CACERTS"; }
cat > "$HOOKS/rhsb-2026-012.json" <<J
{"version":"1.0.0","hook":{"path":"$PWD/hook/rhsb-2026-012-scrub","env":["RHSB_LOG=$LOG","RHSB_JAVA_CACERTS=$PWD/$CACERTS"]},"when":{"always":true},"stages":["prestart"]}
J
IMG=${IMG:-registry.access.redhat.com/ubi9/ubi:9.8-1791888712}   # pre-fix ubi9
T='for h in dv-g3b-emudhra dv-g3b-aaa-emudhra; do printf "%s: " $h; curl -s -o /dev/null -w "%{http_code}\n" -m 10 https://$h.we-have-a-problem.com || echo "rc=$?"; done; printf "quay.io: "; curl -s -o /dev/null -w "%{http_code}\n" -m 10 https://quay.io'
echo "== without hook"; podman run --rm "$IMG" bash -c "$T"
echo "== with hook";    podman --hooks-dir "$HOOKS" run --rm "$IMG" bash -c "$T"
echo "== hook log"; cat "$LOG"; rm -rf "$HOOKS"

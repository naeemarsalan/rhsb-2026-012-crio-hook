#!/bin/bash
# Scenario test on a live OpenShift cluster.
#
# Starts one pod per case in the rhsb-2026-012-test namespace (restricted-v2 SCC,
# random UID) and reports, for each runtime, whether a site that chains to a
# compromised root is reachable and whether a normal site still works.
#
#   OK       site reachable
#   BLOCKED  certificate verification failed
#   ERROR    any other failure (DNS, timeout)
#
# Run it before and after `make deploy` and compare.
set -u
NS=rhsb-2026-012-test
BAD=https://dv-g3b-emudhra.we-have-a-problem.com
GOOD=https://quay.io

UBI9_OLD=registry.access.redhat.com/ubi9/ubi:9.8-1791888712          # before the fix
UBI9_NEW=registry.access.redhat.com/ubi9/ubi:latest
JAVA_OLD=registry.access.redhat.com/ubi9/openjdk-21:1.24-3.1791779559
PYTHON_OLD=docker.io/library/python:3.11.4                             # Debian
NODE=docker.io/library/node:20                                         # embedded CA list

curl_t='for u in '$BAD' '$GOOD'; do curl -s -o /dev/null -m 15 $u; r=$?; case $r in 0) s=OK;; 60) s=BLOCKED;; *) s=ERROR$r;; esac; echo "$u $s"; done'
python_t='import urllib.request
for u in ["'$BAD'", "'$GOOD'"]:
    try: urllib.request.urlopen(u, timeout=15); print(u, "OK")
    except Exception as e: print(u, "OK" if "HTTP Error" in str(e) else "BLOCKED" if "CERTIFICATE_VERIFY_FAILED" in str(e) else "ERROR")'
java_t='cat > /tmp/T.java <<J
public class T { public static void main(String[] a) { for (String u : a) {
  try { var c = (javax.net.ssl.HttpsURLConnection) new java.net.URL(u).openConnection();
        c.setConnectTimeout(15000); c.connect(); System.out.println(u + " OK"); }
  catch (Exception e) { System.out.println(u + (e instanceof javax.net.ssl.SSLException ? " BLOCKED" : " ERROR")); } } } }
J
java /tmp/T.java '$BAD' '$GOOD
node_t='setTimeout(() => process.exit(0), 20000).unref()
for (const u of ["'$BAD'", "'$GOOD'"]) require("https").get(u, r => { console.log(u, "OK"); r.destroy() }).on("error", e => console.log(u, /CERT|ISSUER|SELF_SIGNED/.test(e.code) ? "BLOCKED" : "ERROR"))'

# name | image | security | interpreter | test script (variable name)
CASES=(
  "ubi9-old|$UBI9_OLD|default|bash|curl_t"
  "ubi9-old-readonly|$UBI9_OLD|readonly|bash|curl_t"
  "ubi9-new|$UBI9_NEW|default|bash|curl_t"
  "python-debian|$PYTHON_OLD|default|python3|python_t"
  "java-21|$JAVA_OLD|default|bash|java_t"
  "node-20|$NODE|default|node|node_t"
)

oc get ns $NS >/dev/null 2>&1 || oc create ns $NS >/dev/null
oc -n $NS delete pod -l app=rhsb-test --wait >/dev/null 2>&1

for c in "${CASES[@]}"; do
  IFS='|' read -r name image sec interp script <<<"$c"
  # The script travels base64-encoded so that quotes and newlines survive.
  cmd="echo $(printf '%s' "${!script}" | base64 -w0) | base64 -d > /tmp/t && $interp /tmp/t"
  ro=false; [ "$sec" = readonly ] && ro=true
  cat <<EOF | oc -n $NS apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $name, labels: {app: rhsb-test}}
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: $image
    command: ["sh", "-c", "$cmd"]
    env: [{name: HOME, value: /tmp}]
    volumeMounts: [{name: tmp, mountPath: /tmp}]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: $ro
      capabilities: {drop: [ALL]}
      runAsNonRoot: true
      seccompProfile: {type: RuntimeDefault}
  volumes: [{name: tmp, emptyDir: {}}]
EOF
done

# Wait until every pod has finished, whether it succeeded or failed.
for i in $(seq 120); do
  oc -n $NS get pods -l app=rhsb-test -o jsonpath='{.items[*].status.phase}' |
    grep -qE 'Pending|Running' || break
  sleep 5
done
printf '%-20s %-10s %-10s %s\n' CASE BAD-SITE QUAY.IO PHASE
for c in "${CASES[@]}"; do
  name=${c%%|*}
  out=$(oc -n $NS logs $name 2>/dev/null)
  printf '%-20s %-10s %-10s %s\n' "$name" \
    "$(grep -m1 "^$BAD" <<<"$out" | awk '{print $2}')" \
    "$(grep -m1 "^$GOOD" <<<"$out" | awk '{print $2}')" \
    "$(oc -n $NS get pod $name -o jsonpath='{.status.phase}')"
done

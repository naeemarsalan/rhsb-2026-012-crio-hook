# rhsb-2026-012-crio-hook

CRI-O OCI hook that removes the compromised eMudhra roots (RHSB-2026-012) from every new
container's trust store. No image rebuilds, no node reboot.

Full write-up coming. Quick start:

```bash
IMAGE=$(oc adm release info --image-for=cli) ./deploy/render.sh
oc apply -f rendered/rhsb-2026-012-hook.yaml     # install
oc delete -f rendered/rhsb-2026-012-hook.yaml    # remove
./test/podman-test.sh                            # local proof
```

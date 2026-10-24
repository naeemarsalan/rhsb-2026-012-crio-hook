IMAGE ?= REPLACE_WITH_oc_adm_release_info_--image-for=cli
MANIFEST := rendered/rhsb-2026-012-hook.yaml

.PHONY: manifests deploy undeploy status test fuzz clean

manifests: ## Render the DaemonSet manifest (set IMAGE to the release cli image)
	IMAGE=$(IMAGE) ./hack/render-manifests.sh

deploy: manifests ## Install the hook on every node
	oc apply -f $(MANIFEST)
	oc -n rhsb-2026-012 rollout status ds/hook-installer

undeploy: ## Remove the hook from every node
	oc delete -f $(MANIFEST) --ignore-not-found

status: ## Show installer pods and recent hook activity
	oc -n rhsb-2026-012 get pods -o wide
	oc -n rhsb-2026-012 logs ds/hook-installer --tail=20

test: ## Local before/after check with podman
	./hack/test-podman.sh

fuzz: ## Run the hook against 1000 random container layouts (needs certs/)
	./hack/fuzz-hook.py certs/bad certs/good.pem 1000

clean:
	rm -rf rendered


# Define shell
SHELL = /usr/bin/env bash

# Define phony targets to avoid file conflicts
.PHONY: render-manifests-incremental render-manifests render-manifests-zot zot-up zot-down

PROJECT_ROOT := $(shell git rev-parse --show-toplevel)
export CONTEXT=$(BUILD_CONTEXT)

# Directories that contain both helm-release.yaml and helm-repository.yaml
HELM_DIRS := $(shell \
  find ./k8s -type f -name helm-release.yaml -print0 \
  | xargs -0 -n1 dirname \
  | while read d; do \
      [ -f "$$d/helm-repository.yaml" ] && echo "$$d"; \
    done \
  | sort -u \
)


RENDER_STAMPS := $(addsuffix /rendered/.dummy,$(HELM_DIRS))

# render manifest updates .dummy
# if any %/helm-release.yaml %/helm-repository.yaml is NEWER than your local .dummy
# an incremental render will be performed
render-manifests-incremental: $(RENDER_STAMPS)

%/rendered/.dummy: %/helm-release.yaml %/helm-repository.yaml
	@mkdir -p $(@D)
	cd $(@D)/.. && $(PROJECT_ROOT)/scripts/ci/render-manifests.sh
	@touch $@

# Fallback: always rerun renders, regardless of timestamps
# Renders every component by default; override RENDER_DIRS="dir1 dir2" to limit it
ifeq ($(strip $(RENDER_DIRS)),)
override RENDER_DIRS := $(HELM_DIRS)
endif
render-manifests:
	@set -e; \
	for d in $(RENDER_DIRS); do \
	  mkdir -p "$$d/rendered"; \
	  (cd "$$d" && $(PROJECT_ROOT)/scripts/ci/render-manifests.sh); \
	done

# A local zot with the cluster's pull-through caches (scripts/zot/compose.yaml), to render the way an in-cluster runner does
# (docs/registry-mirrors.md). The first render fills the cache from upstream, later ones read it.
#   make render-manifests-zot [RENDER_DIRS="dir1 dir2"]   starts zot if needed, renders through it, leaves it running
#   make zot-down                                          stops it; the cache volume stays (`down -v` on the compose file empties it)
ZOT_COMPOSE := docker compose -f $(PROJECT_ROOT)/scripts/zot/compose.yaml

zot-up:
	$(ZOT_COMPOSE) up -d
	@for i in $$(seq 1 30); do curl -fs -o /dev/null http://localhost:5000/v2/ && exit 0; sleep 1; done; \
	  echo "zot did not become ready on localhost:5000" >&2; exit 1

zot-down:
	$(ZOT_COMPOSE) down

render-manifests-zot: export ZOT_MIRROR_GHCR := localhost:5000/ghcr-cache
render-manifests-zot: export ZOT_MIRROR_QUAY := localhost:5000/quay-cache
render-manifests-zot: export ZOT_MIRROR_K8S := localhost:5000/k8s-cache
render-manifests-zot: zot-up
	$(MAKE) render-manifests

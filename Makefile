#
# Commands
#

export KO ?= ko
export KUBECTL ?= kubectl
export GIT ?= git
export GO ?= go
export MKDIR_P ?= mkdir -p
export RM_F ?= rm -f
export SHA256SUM ?= shasum -a 256
export SHELLCHECK ?= shellcheck

#
# Variables
#

export PVPOOL_VERSION := $(or $(PVPOOL_VERSION),$(shell $(GIT) describe --tags --always --dirty))
export PVPOOL_TEST_E2E_KUBECONFIG ?=
export PVPOOL_TEST_E2E_STORAGE_CLASS_NAME ?=

export KO_DOCKER_REPO ?= ko.local
export GOFLAGS ?=

#
#
#

MAKEFLAGS += -rR

ARTIFACTS_DIR := artifacts
MANIFEST_DIRS := $(patsubst %/,%,$(wildcard manifests/*/))

MANIFESTS := $(notdir $(MANIFEST_DIRS))

#
# Functions
#

versioned_artifact_dir = $(addprefix $(ARTIFACTS_DIR)/versioned/,$(1))
versioned_artifact_kustomization_yaml = $(addsuffix /kustomization.yaml,$(call versioned_artifact_dir,$(1)))

build_artifact_dir = $(addprefix $(ARTIFACTS_DIR)/build/pvpool-$(PVPOOL_VERSION)/,$(1))
build_artifact_manifest_yaml = $(foreach manifest,$(1),$(addsuffix /pvpool-$(manifest).yaml,$(call build_artifact_dir,$(manifest))))
build_artifact_kustomization_yaml = $(addsuffix /kustomization.yaml,$(call build_artifact_dir,$(1)))

root_relative_to_dir = $(subst $(eval) ,/,$(patsubst %,..,$(subst /, ,$(1))))

#
# Targets
#

.DELETE_ON_ERROR:

.PHONY: all
all: build

# Directories for intermediate and output artifacts.
$(ARTIFACTS_DIR) $(call versioned_artifact_dir,$(MANIFESTS)) $(call build_artifact_dir,$(MANIFESTS)):
	$(MKDIR_P) $@

# Checksums.
%.sha256.asc: %
	cd $(dir $@) && $(SHA256SUM) $(notdir $<) >$(notdir $@)

# The version stamp. This target will be reevaluated each time make is invoked,
# but the timestamp on the file will only be updated if the version has indeed
# changed. (Note: This is *not* .PHONY because the file actually exists!)
$(ARTIFACTS_DIR)/version.stamp: .FORCE | $(ARTIFACTS_DIR)
	printf "%s" "$(PVPOOL_VERSION)" | cmp -s $@ || printf "%s" "$(PVPOOL_VERSION)" >$@

# Creation of Kustomization files for intermediate versioned targets.
$(call versioned_artifact_kustomization_yaml,$(MANIFESTS)): $(call versioned_artifact_kustomization_yaml,%): $(ARTIFACTS_DIR)/version.stamp | $(call versioned_artifact_dir,%)
	$(RM_F) $@
	cd $(call versioned_artifact_dir,$*) \
		&& $(GO) run sigs.k8s.io/kustomize/kustomize/v3 create --resources $(call root_relative_to_dir,$(dir $@))/manifests/$* \
		&& $(GO) run sigs.k8s.io/kustomize/kustomize/v3 edit add configmap pvpool-environment --behavior=merge --from-literal=version="$(PVPOOL_VERSION)"

.PHONY: generate
generate: | $(ARTIFACTS_DIR)
	$(GO) generate ./...

define build_artifact_manifest_yaml_rule
# The releaseable manifest file for the manifest $(1). Always rebuilt.
$(call build_artifact_manifest_yaml,$(1)): generate $(call build_artifact_dir,$(1)) $(call versioned_artifact_kustomization_yaml,$(1)) .FORCE
	$(GO) run sigs.k8s.io/kustomize/kustomize/v3 build $(call versioned_artifact_dir,$(1)) \$(eval)
		| $(KO) resolve -f - >$$@

# The Kustomization file to allow other users to also leverage Kustomize with
# the built target.
$(call build_artifact_kustomization_yaml,$(1)): | $(call build_artifact_manifest_yaml,$(1))
	$(RM_F) $$@
	cd $(call build_artifact_dir,$(1)) \$(eval)
		&& $(GO) run sigs.k8s.io/kustomize/kustomize/v3 create --resources $(notdir $(call build_artifact_manifest_yaml,$(1)))

# The combined manifest and Kustomization rule.
.PHONY: build-$(1)
build-$(1): $(addsuffix .sha256.asc,$(call build_artifact_manifest_yaml,$(1))) $(call build_artifact_kustomization_yaml,$(1))
endef # define build_artifact_manifest_yaml_rule

# We create rules for each of the manifests.
$(foreach manifest,$(MANIFESTS),$(eval $(call build_artifact_manifest_yaml_rule,$(manifest))))

.PHONY: build
build: build-release build-debug

.PHONY: $(addprefix apply-,$(MANIFESTS))
$(addprefix apply-,$(MANIFESTS)): apply-%: build-%
	$(KUBECTL) apply -f $(call build_artifact_manifest_yaml,$*) --prune --selector app.kubernetes.io/name=pvpool

.PHONY: apply
apply: apply-debug

.PHONY: $(addprefix apply-wait-,$(MANIFESTS))
$(addprefix apply-wait-,$(MANIFESTS)):: apply-wait-%: apply-%
	$(KUBECTL) get deployment -n pvpool -o name \
		| xargs -n 1 -t $(KUBECTL) rollout status -n pvpool --watch --timeout 180s

apply-wait-test:: apply-test
	$(KUBECTL) get deployment -n local-path-storage -o name \
		| xargs -n 1 -t $(KUBECTL) rollout status -n local-path-storage --watch --timeout 180s

.PHONY: apply-wait
apply-wait: apply-wait-debug

.PHONY: check
check: generate
	scripts/check

.PHONY: test
ifneq ($(PVPOOL_TEST_E2E_KUBECONFIG),)
test: export KUBECONFIG := $(PVPOOL_TEST_E2E_KUBECONFIG)
test: $(if $(PVPOOL_TEST_E2E_STORAGE_CLASS_NAME),apply-wait-debug,apply-wait-test)
endif # ifneq ($(PVPOOL_TEST_E2E_KUBECONFIG),)
test: generate
	scripts/test

.PHONY: clean
clean:
	$(RM_F) -r $(ARTIFACTS_DIR)/
	$(GO) clean -testcache ./...

.PHONY: .FORCE
.FORCE:

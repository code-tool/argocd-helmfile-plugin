# Local developer entrypoints. CI calls the same targets.

SHELL := /bin/bash

TOOLS_DIR   := $(CURDIR)/.tools
BATS_DIR    := $(TOOLS_DIR)/bats
DOCKERFILE  := docker/Dockerfile
IMAGE       ?= argocd-helmfile-plugin:test

# Tool versions under test are taken from the Dockerfile so tests always
# run against what the image ships. Override on the command line if needed.
HELM_VERSION     ?= $(shell sed -n 's/^ARG HELM_VERSION="\(.*\)"/\1/p' $(DOCKERFILE))
HELMFILE_VERSION ?= $(shell sed -n 's/^ARG HELMFILE_VERSION="\(.*\)"/\1/p' $(DOCKERFILE))

BATS_CORE_VERSION    := v1.14.0
BATS_SUPPORT_VERSION := v0.3.0
BATS_ASSERT_VERSION  := v2.2.4

GO_ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

# Each version lives in its own directory so switching versions never mixes binaries.
HELM_DIR     := $(TOOLS_DIR)/helm/$(HELM_VERSION)
HELMFILE_DIR := $(TOOLS_DIR)/helmfile/$(HELMFILE_VERSION)

export PATH := $(HELM_DIR):$(HELMFILE_DIR):$(PATH)

.PHONY: help tools lint test test-docker clean versions

help:
	@echo "make tools        - download helm, helmfile and bats into $(TOOLS_DIR)"
	@echo "make lint         - run shellcheck"
	@echo "make test         - run bats tests (downloads tools if needed)"
	@echo "make test-docker  - build the image and run a smoke test inside it"
	@echo "make clean        - remove $(TOOLS_DIR)"

versions:
	@echo "helm:     $(HELM_VERSION)"
	@echo "helmfile: $(HELMFILE_VERSION)"

$(HELM_DIR)/helm:
	@mkdir -p $(HELM_DIR)
	wget -qO- "https://get.helm.sh/helm-$(HELM_VERSION)-linux-$(GO_ARCH).tar.gz" \
	  | tar zx --strip-components=1 -C $(HELM_DIR) linux-$(GO_ARCH)/helm

$(HELMFILE_DIR)/helmfile:
	@mkdir -p $(HELMFILE_DIR)
	wget -qO- "https://github.com/helmfile/helmfile/releases/download/v$(HELMFILE_VERSION)/helmfile_$(HELMFILE_VERSION)_linux_$(GO_ARCH).tar.gz" \
	  | tar zx -C $(HELMFILE_DIR) helmfile

$(BATS_DIR)/.installed:
	@mkdir -p $(BATS_DIR)
	git clone -q --depth 1 --branch $(BATS_CORE_VERSION)    https://github.com/bats-core/bats-core    $(BATS_DIR)/bats-core
	git clone -q --depth 1 --branch $(BATS_SUPPORT_VERSION) https://github.com/bats-core/bats-support $(BATS_DIR)/bats-support
	git clone -q --depth 1 --branch $(BATS_ASSERT_VERSION)  https://github.com/bats-core/bats-assert  $(BATS_DIR)/bats-assert
	@touch $@

tools: $(HELM_DIR)/helm $(HELMFILE_DIR)/helmfile $(BATS_DIR)/.installed

# The plugin is checked at error severity for now; it is raised once the
# script cleanup lands. For .bats files:
#   SC2030/SC2031  each @test runs in a subshell by design
#   SC2016         single-quoted $${VAR} is intentional (tests variable expansion)
lint:
	shellcheck --severity=error src/*.sh
	shellcheck test/*.bash test/*.sh
	shellcheck -s bash -e SC2030,SC2031,SC2016 test/*.bats
	@# Helm 2 support was removed, make sure it does not come back.
	@if grep -nE 'init --client-only|HELMFILE_HELM3|helm_major_version\} -eq 2' src/*.sh; then \
	  echo "Helm 2 code found in src/"; exit 1; fi

test: tools
	@helm version --short
	@helmfile --version
	BATS_LIB_PATH=$(BATS_DIR) $(BATS_DIR)/bats-core/bin/bats --print-output-on-failure test/

test-docker:
	docker build -f $(DOCKERFILE) -t $(IMAGE) .
	docker run --rm -v $(CURDIR)/test:/test:ro --entrypoint /bin/bash $(IMAGE) /test/docker-smoke.sh

clean:
	rm -rf $(TOOLS_DIR)

dummy := $(shell touch .env)
include .env
export

# Default values (can be overridden via .env or environment)
IMAGE_NAME  ?= ghcr.io/windemiatrix/amnezia-client-image
IMAGE_TAG   ?= latest
PLATFORMS   ?= linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6
CONFIG_DIR  ?= ./config

AMNEZIAWG_GO_VERSION    ?= v0.2.16
AMNEZIAWG_TOOLS_VERSION ?= v1.0.20250903

# Derived
IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Build

.PHONY: build
build: ## Build Docker image for the current platform.
	docker buildx build \
		--build-arg AMNEZIAWG_GO_VERSION=$(AMNEZIAWG_GO_VERSION) \
		--build-arg AMNEZIAWG_TOOLS_VERSION=$(AMNEZIAWG_TOOLS_VERSION) \
		--load \
		-t $(IMAGE) .

.PHONY: build-multi
build-multi: ## Build multi-arch Docker image (no load).
	docker buildx build \
		--build-arg AMNEZIAWG_GO_VERSION=$(AMNEZIAWG_GO_VERSION) \
		--build-arg AMNEZIAWG_TOOLS_VERSION=$(AMNEZIAWG_TOOLS_VERSION) \
		--platform $(PLATFORMS) \
		-t $(IMAGE) .

##@ Test

.PHONY: test
test: build ## Build and run smoke tests.
	@echo "==> Smoke test: checking binaries..."
	@docker run --rm --entrypoint which $(IMAGE) amneziawg-go
	@docker run --rm --entrypoint which $(IMAGE) awg
	@docker run --rm --entrypoint which $(IMAGE) awg-quick
	@echo "==> Smoke test: checking versions..."
	@docker run --rm --entrypoint amneziawg-go $(IMAGE) --version || true
	@docker run --rm --entrypoint awg $(IMAGE) --version || true
	@echo "==> Smoke test: entrypoint exits with error on missing config..."
	@docker run --rm $(IMAGE) 2>&1 | grep -qi "error\|not found\|no such"
	@echo "==> Smoke test: healthcheck script exists..."
	@docker run --rm --entrypoint sh $(IMAGE) -c "test -x /healthcheck.sh"
	@echo "==> All smoke tests passed."

.PHONY: lint
lint: ## Run Hadolint and ShellCheck.
	@echo "==> Hadolint..."
	@docker run --rm -i hadolint/hadolint < Dockerfile
	@echo "==> ShellCheck..."
	@shellcheck scripts/*.sh
	@echo "==> Lint passed."

##@ Versioning

# Get current version from the latest git tag (strips leading 'v')
CURRENT_VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')

.PHONY: version
version: ## Show the current version (latest git tag).
	@echo "$(CURRENT_VERSION)"

.PHONY: bump-patch
bump-patch: ## Bump patch version (1.0.5 → 1.0.6), update files, commit and tag.
	@if [ -z "$(CURRENT_VERSION)" ]; then echo "Error: no git tags found"; exit 1; fi
	$(eval MAJOR := $(word 1,$(subst ., ,$(CURRENT_VERSION))))
	$(eval MINOR := $(word 2,$(subst ., ,$(CURRENT_VERSION))))
	$(eval PATCH := $(word 3,$(subst ., ,$(CURRENT_VERSION))))
	$(eval NEW_PATCH := $(shell echo $$(($(PATCH)+1))))
	$(eval NEW_VERSION := $(MAJOR).$(MINOR).$(NEW_PATCH))
	@$(MAKE) --no-print-directory set-version NEW_VERSION=$(NEW_VERSION)

.PHONY: bump-minor
bump-minor: ## Bump minor version (1.0.5 → 1.1.0), update files, commit and tag.
	@if [ -z "$(CURRENT_VERSION)" ]; then echo "Error: no git tags found"; exit 1; fi
	$(eval MAJOR := $(word 1,$(subst ., ,$(CURRENT_VERSION))))
	$(eval MINOR := $(word 2,$(subst ., ,$(CURRENT_VERSION))))
	$(eval NEW_MINOR := $(shell echo $$(($(MINOR)+1))))
	$(eval NEW_VERSION := $(MAJOR).$(NEW_MINOR).0)
	@$(MAKE) --no-print-directory set-version NEW_VERSION=$(NEW_VERSION)

.PHONY: bump-major
bump-major: ## Bump major version (1.0.5 → 2.0.0), update files, commit and tag.
	@if [ -z "$(CURRENT_VERSION)" ]; then echo "Error: no git tags found"; exit 1; fi
	$(eval MAJOR := $(word 1,$(subst ., ,$(CURRENT_VERSION))))
	$(eval NEW_MAJOR := $(shell echo $$(($(MAJOR)+1))))
	$(eval NEW_VERSION := $(NEW_MAJOR).0.0)
	@$(MAKE) --no-print-directory set-version NEW_VERSION=$(NEW_VERSION)

.PHONY: set-version
set-version: ## Set version explicitly: make set-version NEW_VERSION=1.2.3
	@if [ -z "$(NEW_VERSION)" ]; then echo "Error: NEW_VERSION is required"; exit 1; fi
	@echo "==> Bumping version: $(CURRENT_VERSION) → $(NEW_VERSION)"
	@sed -i '' 's/^version: ".*"/version: "$(NEW_VERSION)"/' amneziawg-client/config.yaml
	@echo "    Updated amneziawg-client/config.yaml"
	@git add amneziawg-client/config.yaml
	@git commit -m "chore: bump version to $(NEW_VERSION)"
	@git tag "v$(NEW_VERSION)"
	@echo "==> Tagged v$(NEW_VERSION). Push with: git push origin main --tags"

##@ Release

.PHONY: push
push: ## Build and push multi-arch image to registry.
	docker buildx build \
		--build-arg AMNEZIAWG_GO_VERSION=$(AMNEZIAWG_GO_VERSION) \
		--build-arg AMNEZIAWG_TOOLS_VERSION=$(AMNEZIAWG_TOOLS_VERSION) \
		--platform $(PLATFORMS) \
		--push \
		-t $(IMAGE) .

.PHONY: release
release: ## Run goreleaser (requires GITHUB_TOKEN).
	goreleaser release --clean

##@ Development

.PHONY: run
run: build ## Run container with config from CONFIG_DIR.
	docker run -d \
		--name amneziawg \
		--cap-add NET_ADMIN \
		--cap-add SYS_MODULE \
		--device /dev/net/tun:/dev/net/tun \
		--sysctl net.ipv4.conf.all.src_valid_mark=1 \
		--sysctl net.ipv4.ip_forward=1 \
		-v $(CONFIG_DIR):/config \
		$(IMAGE)

.PHONY: stop
stop: ## Stop and remove the running container.
	docker stop amneziawg 2>/dev/null || true
	docker rm amneziawg 2>/dev/null || true

.PHONY: logs
logs: ## Show container logs.
	docker logs -f amneziawg

.PHONY: shell
shell: build ## Open a shell inside the container.
	docker run --rm -it \
		--cap-add NET_ADMIN \
		--device /dev/net/tun:/dev/net/tun \
		--entrypoint /bin/bash \
		$(IMAGE)

##@ Clean

.PHONY: clean
clean: stop ## Stop container, remove image and .env.
	docker rmi $(IMAGE) 2>/dev/null || true
	@echo "==> Clean complete."

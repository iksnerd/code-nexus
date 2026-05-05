.PHONY: deps compile test test.all format format.check \
	build run stop logs \
	docker.buildx docker.build docker.push docker.publish docker.publish.fresh docker.publish.local \
	tag release clean

IMAGE := iksnerd/code-nexus
VERSION := $(shell grep -E '^\s*version:' mix.exs | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
TAG := v$(VERSION)
PLATFORMS := linux/amd64,linux/arm64
BUILDER := nexus-multiarch

## Development

deps:
	mix deps.get

compile: deps
	mix compile --warnings-as-errors

test: compile
	mix test --exclude performance --exclude multi_project --exclude nif --exclude file_watcher

test.all: compile
	mix test

format:
	mix format

format.check:
	mix format --check-formatted

## Docker (local single-arch via docker-compose)

build:
	docker-compose build code_nexus

run:
	WORKSPACE=~/www docker-compose up -d

stop:
	docker-compose down

logs:
	docker logs -f code_nexus

## Docker Hub publish (multi-arch via buildx)

# Ensure a buildx builder exists for multi-arch builds.
docker.buildx:
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 || \
		docker buildx create --name $(BUILDER) --use --bootstrap

# Build multi-arch image locally without pushing (verifies the build).
docker.build: docker.buildx
	docker buildx build \
		--platform $(PLATFORMS) \
		-t $(IMAGE):$(TAG) \
		-t $(IMAGE):latest \
		.

# Build and push multi-arch image to Docker Hub.
# This is the main release command — replaces the old CI publish job.
docker.publish: docker.buildx
	@echo "Publishing $(IMAGE):$(TAG) and :latest for $(PLATFORMS)"
	docker buildx build \
		--platform $(PLATFORMS) \
		-t $(IMAGE):$(TAG) \
		-t $(IMAGE):latest \
		--push \
		.

# Full rebuild from scratch — use after Dockerfile, .dockerignore, or .agents/ changes.
docker.publish.fresh: docker.buildx
	@echo "Publishing $(IMAGE):$(TAG) and :latest (--no-cache) for $(PLATFORMS)"
	docker buildx build \
		--no-cache \
		--platform $(PLATFORMS) \
		-t $(IMAGE):$(TAG) \
		-t $(IMAGE):latest \
		--push \
		.

# Local-only single-arch build for fast iteration (host platform).
docker.publish.local:
	docker build -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

## Release

# Bump version in mix.exs first, then run `make release`.
# This runs the pre-push checks, tags the commit, pushes the tag,
# and publishes a multi-arch image to Docker Hub.
release: format.check test
	@echo "Tagging $(TAG)..."
	@git tag -a $(TAG) -m "Release $(TAG)" 2>/dev/null || echo "Tag $(TAG) already exists"
	@git push origin $(TAG)
	$(MAKE) docker.publish
	@echo "Released $(TAG) — image pushed to Docker Hub"

# Just create + push a tag (no docker build).
tag:
	@echo "Current version in mix.exs: $(VERSION)"
	@echo "Tagging $(TAG)..."
	git tag -a $(TAG) -m "Release $(TAG)"
	git push origin $(TAG)

## Cleanup

clean:
	mix clean
	rm -rf _build deps

# Remove old image tags from local Docker, keeping only :latest and current $(TAG).
clean.images:
	@echo "Keeping $(IMAGE):latest and $(IMAGE):$(TAG)"
	@docker images --format '{{.Repository}}:{{.Tag}}' | \
		grep '^$(IMAGE):v' | \
		grep -v '^$(IMAGE):$(TAG)$$' | \
		xargs -r docker rmi || true

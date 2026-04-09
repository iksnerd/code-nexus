.PHONY: build test format lint publish run stop clean

IMAGE := iksnerd/elixir-nexus
TAG := $(shell git describe --tags --always 2>/dev/null || echo "dev")

## Development

deps:
	mix deps.get

compile: deps
	mix compile

test: compile
	mix test --exclude performance

test.all: compile
	mix test

format:
	mix format

format.check:
	mix format --check-formatted

## Docker

build:
	docker-compose build elixir_nexus

run:
	WORKSPACE=~/www docker-compose up -d

stop:
	docker-compose down

logs:
	docker logs -f elixir_nexus

## Publish to Docker Hub

publish: publish.latest publish.tag

publish.latest:
	docker build -t $(IMAGE):latest .
	docker push $(IMAGE):latest

publish.tag:
	docker build -t $(IMAGE):$(TAG) .
	docker push $(IMAGE):$(TAG)

## Release

tag:
	@echo "Current tags:"; git tag --list | sort -V | tail -5
	@read -p "New version (e.g. v0.2.0): " version; \
	git tag -a $$version -m "Release $$version"; \
	echo "Tagged $$version. Run 'git push origin $$version' to publish."

release: format.check test build publish
	@echo "Released $(TAG)"

## Cleanup

clean:
	mix clean
	rm -rf _build deps

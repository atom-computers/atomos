.PHONY: test test-unit test-integration test-integration-shell test-all lint clean venv

PYTHONPATH := src
DOCKER     := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
IMAGE      := atomos-agents-test

# Prefer the local venv when present (macOS dev), fall back to system python3
# (Linux/CI where deps are installed system-wide).
PYTHON := $(shell \
	if [ -x ".venv/bin/python" ]; then echo ".venv/bin/python"; \
	elif [ -x ".venv/bin/python3" ]; then echo ".venv/bin/python3"; \
	else echo "python3"; fi)

# ---------------------------------------------------------------------------
# Unit tests — fast, no container, all browser/OS calls mocked
# ---------------------------------------------------------------------------

test: test-unit

test-unit:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m pytest tests/ -m "not integration" -v --tb=short --ignore=tests/test_integration_managers.py

# Create / update the local dev venv
venv:
	python3 -m venv .venv
	.venv/bin/pip install -e ".[dev]"

# ---------------------------------------------------------------------------
# Integration tests — run inside a Linux container matching the ISO runtime
# ---------------------------------------------------------------------------

test-integration: _check-docker _build-test-image
	$(DOCKER) run --rm \
		-e ATOMOS_INTEGRATION_TEST=1 \
		$(IMAGE)

test-integration-shell: _check-docker _build-test-image
	$(DOCKER) run --rm -it \
		-e ATOMOS_INTEGRATION_TEST=1 \
		$(IMAGE) bash

# ---------------------------------------------------------------------------
# Run everything: unit tests on host, integration tests in container
# ---------------------------------------------------------------------------

test-all: test-unit test-integration

# ---------------------------------------------------------------------------
# Internal targets
# ---------------------------------------------------------------------------

_build-test-image:
	$(DOCKER) build -f Dockerfile.test -t $(IMAGE) .

_check-docker:
	@if [ -z "$(DOCKER)" ]; then \
		echo "Error: docker or podman not found. Install one to run integration tests."; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

lint:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m pytest tests/ -m "not integration" --co -q --ignore=tests/test_integration_managers.py

clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true

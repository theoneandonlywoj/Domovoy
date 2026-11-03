.PHONY: help self iex iex-start-dev env-init env-setup-dev env-start-dev env-stop-dev env-ping-dev livebook-start-dev livebook-stop-dev livebook-logs-dev db-start-dev db-stop-dev db-logs-dev db-force-stop-dev db-setup-dev db-reset-dev db-seed-dev db-seed-test watchman-install git-hooks-setup precommit quality test dev-check-make dev-check-postgres

self:
	cat Makefile

help: self

_PODMAN_SOCKET := $(shell podman machine inspect podman-machine-default --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)
ifneq ($(_PODMAN_SOCKET),)
DOCKER_HOST ?= unix://$(_PODMAN_SOCKET)
endif
export DOCKER_HOST

# Auto-detect container runtime (podman or docker, with or without sudo)
_HAS_PODMAN := $(shell command -v podman 2>/dev/null)
_HAS_DOCKER := $(shell command -v docker 2>/dev/null)

ifdef _HAS_PODMAN
  _COMPOSE_DIRECT := $(shell podman compose version >/dev/null 2>&1 && echo "podman compose" || echo "")
  ifdef _COMPOSE_DIRECT
    COMPOSE ?= podman compose
  else
    COMPOSE ?= sudo podman compose
  endif
  CONTAINER ?= podman
else ifdef _HAS_DOCKER
  _COMPOSE_DIRECT := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "")
  ifdef _COMPOSE_DIRECT
    COMPOSE ?= docker compose
  else
    COMPOSE ?= sudo docker compose
  endif
  CONTAINER ?= docker
else
  COMPOSE ?= podman compose
  CONTAINER ?= podman
endif

DB_PROJECT ?= domovoy-dev-db
DB_WAIT_SECONDS ?= 60
export DB_WAIT_SECONDS
# Empty: LIVEBOOK_PROJECT from the environment or .env applies, else domovoy-livebook.
LIVEBOOK_PROJECT ?=
LIVEBOOK_WAIT_SECONDS ?= 120
export LIVEBOOK_WAIT_SECONDS
# DOMOVOY_ENV_FILE: unset discovers own/main .env; explicit empty disables discovery.

# Targets are named {what}-{action}-{env}; tools with no environment use {what}-{action}.

# `iex` defaults to the dev environment
iex: iex-start-dev

iex-start-dev:
	@python3 scripts/dev_services.py iex

# Livebook attached to `make iex` (trusted local use only; macOS Podman):
#   1. make env-init            # once, where your .env lives: generates BORG_DIST_COOKIE
#   2. make iex                 # terminal A: Phoenix in IEx as domovoy@host.containers.internal
#   3. make livebook-start-dev  # terminal B: first run builds the image (several minutes),
#                               # then prints http://127.0.0.1:8080; open it, there is no login
#   4. New notebooks run on the `make iex` node; save them in docs/livebooks/ (Livebook's home).
#   5. make livebook-logs-dev   # follow logs;  make livebook-stop-dev  # stop and remove it
#   6. Second checkout at the same time: give it its own .env with BORG_NODE_NAME, LIVEBOOK_PORT,
#      LIVEBOOK_IFRAME_PORT and LIVEBOOK_PROJECT, so start, stop and logs act on its own instance.
#   7. `iex --remsh` from macOS needs "127.0.0.1 host.containers.internal" in /etc/hosts.
# "node ... is unreachable" in a notebook: start `make iex`, then reconnect the runtime.
# After changing BORG_DIST_COOKIE, restart Livebook (stop, then start).
# Slow first start: `make livebook-start-dev LIVEBOOK_WAIT_SECONDS=300` waits longer for health.
# Anything that can reach 127.0.0.1:LIVEBOOK_PORT can run code on the node; never expose it.


# Build on first run, start Livebook attached to `make iex`, wait for health and print the URL.
livebook-start-dev:
	@python3 scripts/dev_services.py start --service livebook --compose "$(COMPOSE)" --project "$(LIVEBOOK_PROJECT)"

# Stop and remove Livebook without needing local secrets; its data volume is kept.
livebook-stop-dev:
	@python3 scripts/dev_services.py stop --service livebook --compose "$(COMPOSE)" --project "$(LIVEBOOK_PROJECT)"

# Follow Livebook logs without reading local secrets.
livebook-logs-dev:
	@python3 scripts/dev_services.py logs --service livebook --compose "$(COMPOSE)" --project "$(LIVEBOOK_PROJECT)"


# Start the selected DB project and verify authenticated PostgreSQL access.
db-start-dev:
	@python3 scripts/dev_services.py start --compose "$(COMPOSE)" --project "$(DB_PROJECT)"

# Stop the selected project without needing local secrets or deleting its volume.
db-stop-dev:
	@python3 scripts/dev_services.py stop --compose "$(COMPOSE)" --project "$(DB_PROJECT)"

# Follow logs without reading local secrets.
db-logs-dev:
	@python3 scripts/dev_services.py logs --compose "$(COMPOSE)" --project "$(DB_PROJECT)"

# Remove orphans and the selected project's network, retaining database volumes.
db-force-stop-dev:
	@python3 scripts/dev_services.py force-stop --compose "$(COMPOSE)" --container "$(CONTAINER)" --project "$(DB_PROJECT)"

db-setup-dev:
	MIX_ENV=dev mix ecto.setup

git-hooks-setup:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit .githooks/pre-push

# Create .env from .env.example (if missing) and replace placeholder secrets.
env-init:
	@if [ ! -f .env ]; then cp .env.example .env; echo "Created .env from .env.example"; fi
	@if grep -qE '^POSTGRES_PASSWORD=(replace-with-a-generated-private-password|change-me|your-)' .env 2>/dev/null || grep -qE '^POSTGRES_PASSWORD=(postgres|password|secret|placeholder)$$' .env 2>/dev/null; then \
	  PW=$$(openssl rand -hex 24); \
	  sed -i.bak "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$$PW/" .env && rm -f .env.bak; \
	  echo "Generated POSTGRES_PASSWORD in .env"; \
	fi
	@if ! grep -qE '^(export[[:space:]]+)?BORG_DIST_COOKIE=' .env; then \
  	  CK=$$(openssl rand -hex 24) && [ -n "$$CK" ] || { echo "openssl failed; BORG_DIST_COOKIE not generated" >&2; exit 1; }; \
  	  if [ -n "$$(tail -c1 .env)" ]; then echo >> .env; fi; \
  	  printf 'BORG_DIST_COOKIE=%s\n' "$$CK" >> .env; \
  	  echo "Generated BORG_DIST_COOKIE in .env"; \
  	elif ! grep -qE '^(export[[:space:]]+)?BORG_DIST_COOKIE=[A-Za-z0-9_-]+$$' .env || \
  	     grep -E '^(export[[:space:]]+)?BORG_DIST_COOKIE=' .env | tail -1 | cut -d= -f2- | \
  	       grep -qiE '^(replace|change|your-|mysecretcookie$$|cookie$$|secret$$|placeholder$$)'; then \
  	  CK=$$(openssl rand -hex 24) && [ -n "$$CK" ] || { echo "openssl failed; BORG_DIST_COOKIE not generated" >&2; exit 1; }; \
  	  sed -i.bak -E "s/^(export[[:space:]]+)?BORG_DIST_COOKIE=.*/BORG_DIST_COOKIE=$$CK/" .env && rm -f .env.bak; \
  	  echo "Generated BORG_DIST_COOKIE in .env"; \
  	fi

env-setup-dev: env-init watchman-install db-start-dev db-setup-dev git-hooks-setup
	@echo "Development environment setup complete."

watchman-install:
	@if command -v watchman >/dev/null 2>&1; then \
		echo "watchman already installed"; \
	else \
		echo "Installing watchman..."; \
		if command -v apt-get >/dev/null 2>&1; then \
			sudo apt-get update && sudo apt-get install -y watchman; \
		elif command -v brew >/dev/null 2>&1; then \
			brew install watchman; \
		elif command -v dnf >/dev/null 2>&1; then \
			sudo dnf install -y watchman; \
		elif command -v yay >/dev/null 2>&1; then \
			yay -S --noconfirm watchman-bin || yay -S --noconfirm watchman; \
		elif command -v paru >/dev/null 2>&1; then \
			paru -S --noconfirm watchman-bin || paru -S --noconfirm watchman; \
		elif command -v pacman >/dev/null 2>&1; then \
			echo "watchman is not available in the official Arch repositories."; \
			echo "Install an AUR helper (yay/paru) and run one of:"; \
			echo "  yay -S watchman-bin"; \
			echo "  yay -S watchman"; \
			exit 1; \
		else \
			echo "No supported package manager found. Please install watchman manually."; \
			exit 1; \
		fi \
	fi

# Start all dev services
env-start-dev: db-start-dev
	@echo "All services are ready."

env-stop-dev: db-stop-dev
	@echo "All services stopped."

env-ping-dev:
	@echo "=== Domovoy Dev Environment Status ==="
	@echo ""
	@printf "  %-25s " "Phoenix (localhost:4000)" && (curl -sf -o /dev/null http://localhost:4000 2>/dev/null && echo "✓ UP" || echo "✗ DOWN")
	@python3 scripts/dev_services.py ping

db-reset-dev:
	MIX_ENV=dev mix ecto.reset

db-seed-dev:
	MIX_ENV=dev mix run priv/repo/seeds.exs

db-seed-test:
	MIX_ENV=test mix run priv/repo/seeds.exs

# Run compile warnings, format, Credo and the tests (mix precommit)
precommit:
	mix precommit

# Run compile warnings, formatting, Credo and Dialyzer checks
quality:
	mix quality

# Run tests
test:
	MIX_ENV=test mix test

# Validate Makefile recipes against stubbed dev-service behavior.
dev-check-make:
	python3 scripts/check_dev_services.py make

# Validate isolated PostgreSQL 18.4 service, runtime, network and source checks.
dev-check-postgres:
	python3 scripts/check_dev_services.py postgres

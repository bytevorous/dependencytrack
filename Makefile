PROJECT       := dependencytrack
EDITOR        ?= nano
FRONTEND_PORT ?= 8080
URL           ?= http://localhost:$(FRONTEND_PORT)

# macOS: plain docker, brew, `open`. Linux: sudo docker, apt, firefox.
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
DOCKER ?= docker
else
DOCKER ?= sudo docker
endif
COMPOSE := $(DOCKER) compose -p $(PROJECT)

.DEFAULT_GOAL := help
.PHONY: help newcompose install install-docker install-syft install-firefox up start stop rm update

# Typing just `make` lists every target that has a "## description" after it
help: ## Show this list
	@echo "Usage: make <target>"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'
	@echo
	@echo "Options: FRONTEND_PORT=$(FRONTEND_PORT)  EDITOR=$(EDITOR)  (e.g. make up FRONTEND_PORT=9090)"

# Download the compose file and open it for editing (change the default port here)
newcompose: ## Download docker-compose.yml and open it in your editor (asks before replacing an existing file)
	@if [ -f docker-compose.yml ]; then \
		printf "docker-compose.yml already exists. Replace it? [y/N] "; \
		read ans; \
		case "$$ans" in \
			y|Y|yes|YES) bak="docker-compose.yml.bak.$$(date +%Y%m%d-%H%M%S)"; \
				cp docker-compose.yml "$$bak"; echo "Old file saved as $$bak" ;; \
			*) echo "Keeping existing docker-compose.yml."; exit 0 ;; \
		esac; \
	fi; \
	curl -LO https://dependencytrack.org/docker-compose.yml && $(EDITOR) docker-compose.yml

# Install Firefox if it is not already present
install-firefox: ## Install Firefox if missing
ifeq ($(UNAME),Darwin)
	@if [ -d /Applications/Firefox.app ]; then echo "Firefox already installed"; else brew install --cask firefox; fi
else
	@if command -v firefox >/dev/null 2>&1; then echo "Firefox already installed"; else sudo apt-get update && sudo apt-get install -y firefox; fi
endif

# Compose up, then open the UI in Firefox
up: start ## Start the containers and open the UI in Firefox
	@echo "Opening $(URL) in Firefox (give it a minute to finish starting)..."
ifeq ($(UNAME),Darwin)
	@open -a Firefox $(URL)
else
	@firefox $(URL) >/dev/null 2>&1 &
endif

# Start the containers in the background
start: ## Start the containers in the background
	$(COMPOSE) up -d

# Stop this project's containers only (they are kept, not removed)
stop: ## Stop this project's containers (use 'make rm' to remove them)
	$(COMPOSE) stop

# Stop (if running) and remove this project's containers; networks and volumes are left alone
rm: ## Stop and remove the containers this project created (volumes/data are kept)
	$(COMPOSE) rm -sf

# Scan the host + running containers with syft and upload the SBOMs to Dependency-Track
update: ## Scan host + running containers with syft and upload SBOMs to Dependency-Track
	@bash ./alldeps.sh

# Install everything needed: docker, syft, firefox (each skipped if already present)
install: install-docker install-syft install-firefox ## Install docker, syft and firefox (skips what's present)

install-docker: ## Install Docker if missing
ifeq ($(UNAME),Darwin)
	@if command -v docker >/dev/null 2>&1; then echo "Docker already installed"; else brew install --cask docker; fi
else
	@if command -v docker >/dev/null 2>&1; then echo "Docker already installed"; else sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2; fi
endif

install-syft: ## Install Syft if missing
ifeq ($(UNAME),Darwin)
	@if command -v syft >/dev/null 2>&1; then echo "Syft already installed"; else brew install syft; fi
else
	@if command -v syft >/dev/null 2>&1; then echo "Syft already installed"; else curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin; fi
endif

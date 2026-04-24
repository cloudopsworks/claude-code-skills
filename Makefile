##
# (c) 2021-2026
#     Cloud Ops Works LLC - https://cloudops.works/
#     Find us on:
#       GitHub: https://github.com/cloudopsworks
#       WebSite: https://cloudops.works
#     Distributed Under Apache v2.0 License
#
SHELL := /bin/bash

# List of targets the `readme` target should call before generating the readme
export README_DEPS ?= docs/targets.md

GOMPLATE ?= $(if $(wildcard $(CURDIR)/.bin/gomplate),$(CURDIR)/.bin/gomplate,gomplate)
GOMPLATE_VERSION ?= v5.0.0
README_TEMPLATE ?= templates/README.md.gotmpl
README_YAML ?= README.yaml
README_OUTPUT ?= README.md
README_INCLUDES ?= file://$(CURDIR)/?type=text/plain
README_CURRENT_YEAR ?= $(shell date +%Y)

.PHONY: help help/all help/short init readme readme/deps

help: help/short

help/all: help/short

help/short:
	@printf '%s\n\n' 'Available targets:'
	@printf '  %-35s %s\n' 'help' 'Help screen'
	@printf '  %-35s %s\n' 'help/all' 'Display help for all targets'
	@printf '  %-35s %s\n' 'help/short' 'This help short screen'
	@printf '  %-35s %s\n' 'init' 'Prepare local README generation directories'
	@printf '  %-35s %s\n' 'readme' 'Generate README.md from README.yaml'
	@printf '  %-35s %s\n' 'readme/deps' 'Install gomplate locally when missing'

init:
	@mkdir -p .bin
	@test -f "$(README_TEMPLATE)"

readme/deps: init
	@if command -v "$(GOMPLATE)" >/dev/null 2>&1; then \
		exit 0; \
	fi; \
	os="$$(uname -s | tr '[:upper:]' '[:lower:]')"; \
	arch="$$(uname -m)"; \
	case "$$arch" in \
		x86_64|amd64) arch="amd64" ;; \
		arm64|aarch64) arch="arm64" ;; \
		*) echo "Unsupported architecture: $$arch" >&2; exit 1 ;; \
	esac; \
	curl -fsSL -o .bin/gomplate "https://github.com/hairyhenderson/gomplate/releases/download/$(GOMPLATE_VERSION)/gomplate_$${os}-$${arch}"; \
	chmod +x .bin/gomplate

readme: readme/deps
	README_YAML="$(CURDIR)/$(README_YAML)" \
	README_INCLUDES="$(README_INCLUDES)" \
	README_CURRENT_YEAR="$(README_CURRENT_YEAR)" \
	"$(GOMPLATE)" --file "$(README_TEMPLATE)" --out "$(README_OUTPUT)"
	@perl -pi -e 's/[ \t]+$$//' "$(README_OUTPUT)"
	@printf 'Generated %s from %s using %s\n' "$(README_OUTPUT)" "$(README_YAML)" "$(README_TEMPLATE)"

PREFIX ?= $(HOME)/.local
BIN = .build/release/appshot

.PHONY: help build test install uninstall clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the release binary
	swift build -c release

test: ## Run the unit tests
	swift test

install: build ## Install appshot into $(PREFIX)/bin
	@mkdir -p "$(PREFIX)/bin"
	@install -m 0755 "$(BIN)" "$(PREFIX)/bin/appshot"
	@echo "installed $$($(PREFIX)/bin/appshot --version 2>/dev/null || echo appshot) → $(PREFIX)/bin/appshot"

uninstall: ## Remove the installed binary
	@rm -f "$(PREFIX)/bin/appshot"

clean: ## Remove build products
	swift package clean
	@rm -rf .build

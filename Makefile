PREFIX ?= $(HOME)/.local
BIN = .build/release/appshot

.PHONY: help build test bench fixture install uninstall clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the release binary
	swift build -c release

test: ## Run the unit tests
	swift test

fixture: ## Build the fixture app used by `make bench`
	@Scripts/make-fixture-app.sh

# Not a CI target and never will be: it needs Screen Recording permission and takes
# over the pointer, neither of which a headless runner has. It exists because the
# settle defaults were reasoned from the capture loop's shape rather than measured,
# and this is what measures them.
bench: fixture ## Capture the fixture app and report where the time goes
	@echo
	swift run -c release appshot capture \
	  --app .build/fixture/AppShotFixture.app \
	  --out .build/fixture/shots \
	  --screens instant late restless slow-window \
	  --appearances dark \
	  --timings

install: build ## Install appshot into $(PREFIX)/bin
	@mkdir -p "$(PREFIX)/bin"
	@install -m 0755 "$(BIN)" "$(PREFIX)/bin/appshot"
	@echo "installed $$($(PREFIX)/bin/appshot --version 2>/dev/null || echo appshot) → $(PREFIX)/bin/appshot"

uninstall: ## Remove the installed binary
	@rm -f "$(PREFIX)/bin/appshot"

clean: ## Remove build products
	swift package clean
	@rm -rf .build

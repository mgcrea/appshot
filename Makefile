PREFIX ?= $(HOME)/.local
BIN = .build/release/appshot

.PHONY: help build test bench bench-no-activate bench-record fixture install uninstall clean

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

# Positive controls for the --no-activate guard: a well-behaved stage that must pass
# and two that break the promise, which must fail with their own error. Not CI either,
# for the same reasons as bench — and each control takes the screen for about a second,
# because that is what it tests.
bench-no-activate: fixture ## Prove the --no-activate guard fails when it should
	@swift build -c release --product appshot >&2
	@Scripts/bench-no-activate.sh

# Not CI, for the same reasons as bench: Screen Recording and a window server. Records
# the fixture's video stage and composes it, so the whole video path runs on one command.
bench-record: fixture ## Record the fixture app and compose the promo
	@swift build -c release --product appshot >&2
	.build/release/appshot record --app .build/fixture/AppShotFixture.app \
	  --config Scripts/fixture-video.config.json --out .build/fixture/videos/source --no-activate
	.build/release/appshot compose video --config Scripts/fixture-video.config.json \
	  --source .build/fixture/videos/source --out .build/fixture/videos

install: build ## Install appshot into $(PREFIX)/bin
	@mkdir -p "$(PREFIX)/bin"
	@install -m 0755 "$(BIN)" "$(PREFIX)/bin/appshot"
	@echo "installed $$($(PREFIX)/bin/appshot --version 2>/dev/null || echo appshot) → $(PREFIX)/bin/appshot"

uninstall: ## Remove the installed binary
	@rm -f "$(PREFIX)/bin/appshot"

clean: ## Remove build products
	swift package clean
	@rm -rf .build

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

help:  ## This overview
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

check: ## Check JSON + bash syntax + catalog consistency locally
	@for f in config/*.json; do jq -e . $$f >/dev/null && echo "ok: $$f"; done
	@for f in $$(find . -name '*.sh'); do bash -n $$f || exit 1; done; echo "ok: bash -n"
	@tests/commit-msg.test.sh > /dev/null && echo "ok: commit-msg hook (cases)"
	@tests/pr-gate.test.sh > /dev/null && echo "ok: pr-gate branch deletion (cases)"
	@tests/identity.test.sh > /dev/null && echo "ok: e2e shell identity (cases)"
	@lib/readback-compare.test.sh > /dev/null && echo "ok: read-back comparison (cases)"
	@lib/report-moved.test.sh > /dev/null && echo "ok: report-moved condition (cases)"
	@lib/wallpaper-drifted.test.sh > /dev/null && echo "ok: wallpaper-drift condition (cases)"
	@lib/zones.test.sh > /dev/null && echo "ok: zone selection (cases)"
	@lib/launcher-plan.test.sh > /dev/null && echo "ok: launcher push decision (cases)"
	@lib/andashi.test.sh > /dev/null && echo "ok: andashi decisions (cases)"
	@lib/apk-version-lock.test.sh > /dev/null && echo "ok: versionCode without aapt2 (cases)"
	@tests/from-lock.test.sh > /dev/null && echo "ok: downloads from the lock (cases)"
	@tests/fetch-direct.test.sh > /dev/null && echo "ok: vendor directory and signature (cases)"
	@tests/updater.test.sh > /dev/null && echo "ok: the updater on the device (cases)"
	@tests/updater-config.test.sh > /dev/null && echo "ok: updater config push (cases)"
	@tests/lock.test.sh > /dev/null && echo "ok: writing the lock (cases)"
	@tests/refresh-lock.test.sh > /dev/null && echo "ok: lock refresh routine (cases)"
	@tests/heartbeat.test.sh > /dev/null && echo "ok: lock heartbeat (cases)"
	@apks/check-lock.test.sh > /dev/null && echo "ok: lock consistency (cases)"
	@apks/check-lock.sh
	@config/check-schema.test.sh > /dev/null && echo "ok: schema check (cases)"
	@config/check-contacts.test.sh > /dev/null && echo "ok: contact rule (cases)"
	@config/check-appwidgets.test.sh > /dev/null && echo "ok: appwidget tripwire (cases)"
	@config/check-invariants.test.sh > /dev/null && echo "ok: catalog invariants (cases)"
	@config/check-hosts.test.sh > /dev/null && echo "ok: allowed hosts (cases)"
	@config/gen-updater.test.sh > /dev/null && echo "ok: updater config generation (cases)"
	@tests/andashi-catalog.test.sh > /dev/null && echo "ok: andashi catalog commands (cases)"
	@config/check-schema.sh
	@config/check-contacts.sh
	@config/check-appwidgets.sh
	@config/check-invariants.sh
	@config/check-hosts.sh
	@t=$$(mktemp); OUT=$$t config/gen-obtainium.sh >/dev/null; \
	  if diff -q <(jq -S . $$t) <(jq -S . config/obtainium.json) >/dev/null; then \
	    echo "ok: obtainium.json in sync"; else \
	    echo "obtainium.json is stale - run 'make obtainium'"; diff <(jq -S . config/obtainium.json) <(jq -S . $$t) | head -20; \
	    rm -f $$t; exit 1; fi; rm -f $$t
	@t=$$(mktemp -d); OUT_DIR=$$t config/gen-launcher.sh >/dev/null; \
	  if diff -rq -x ".*" config/launcher $$t >/dev/null; then \
	    echo "ok: launcher/*.json in sync"; else \
	    echo "config/launcher is stale - run 'make launcher-config'"; diff -r config/launcher $$t | head -20; \
	    rm -rf $$t; exit 1; fi; rm -rf $$t

	@t=$$(mktemp -d); OUT_DIR=$$t config/gen-updater.sh >/dev/null; \
	  if diff -rq -x ".*" config/updater $$t >/dev/null; then \
	    echo "ok: updater/*.json in sync"; else \
	    echo "config/updater is stale - run 'make updater-config'"; diff -r config/updater $$t | head -20; \
	    rm -rf $$t; exit 1; fi; rm -rf $$t

schema: ## Refresh config/schema/launcher.schema.json from the newest launcher release
	@tag=$$(gh release view --repo andashi/home --json tagName -q .tagName); \
	  tmp=$$(mktemp -d); \
	  gh release download $$tag --repo andashi/home --pattern 'launcher.schema.json' --dir $$tmp; \
	  gh release download $$tag --repo andashi/home --pattern 'SHA256SUMS' --dir $$tmp; \
	  want=$$(awk '$$2 ~ /launcher\.schema\.json$$/ { print $$1 }' $$tmp/SHA256SUMS); \
	  got=$$(sha256sum $$tmp/launcher.schema.json | cut -d' ' -f1); \
	  [ -n "$$want" ] || { echo "$$tag: SHA256SUMS names no launcher.schema.json"; rm -rf $$tmp; exit 1; }; \
	  [ "$$want" = "$$got" ] || { echo "$$tag: schema hash mismatch"; echo "  want $$want"; echo "  got  $$got"; rm -rf $$tmp; exit 1; }; \
	  mv $$tmp/launcher.schema.json config/schema/launcher.schema.json; \
	  printf '%s\n%s  launcher.schema.json\n' "$$tag" "$$got" > config/schema/FROM; \
	  rm -rf $$tmp; \
	  echo "schema from $$tag, hash verified"; \
	  config/check-schema.sh

todo: ## List unverified package names
	@jq -r '.apps[]|select(.pkg_status=="unverified")|"  \(.label)  ->  \(.pkg)"' config/apps.json

obtainium: ## Regenerate config/obtainium.json
	@config/gen-obtainium.sh

launcher-config: ## Regenerate config/launcher/*.json
	@config/gen-launcher.sh

updater-config: ## Regenerate config/updater/*.json
	@config/gen-updater.sh

manual: ## Regenerate MANUAL.md
	@provision/90-manual.sh

update: ## Fetch newer APKs, verify them, bring every zone to them
	@apks/fetch.sh
	@apks/verify.sh
	@provision/run.sh

apks: ## Verify APK hashes + signer certs (offline)
	@apks/verify.sh

lock: ## Maintainer: write apks/lock.json from the verified inventory (after fetch + apks)
	@apks/lock.sh

from-lock: ## Get the APKs from apks/lock.json - curl, sha256sum, jq, nothing else
	@apks/from-lock.sh

provenance: ## Re-audit where each pinned signer comes from (needs network)
	@apks/provenance.sh

emulator: ## Check emulator prerequisites
	@emulator/build.sh prereqs

.PHONY: help check todo obtainium launcher-config updater-config manual update apks lock from-lock provenance emulator

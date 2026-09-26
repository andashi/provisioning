.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

help:  ## This overview
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

check: ## Check JSON + bash syntax + catalog consistency locally
	@for f in config/*.json; do jq -e . $$f >/dev/null && echo "ok: $$f"; done
	@for f in $$(find . -name '*.sh'); do bash -n $$f || exit 1; done; echo "ok: bash -n"
	@dupes=$$(jq -r '.apps[].pkg' config/apps.json | sort | uniq -d); \
	  [ -z "$$dupes" ] || { echo "Duplicate packages: $$dupes"; exit 1; }; echo "ok: catalog"
	@unreachable=$$(jq -r -n --slurpfile a config/apps.json --slurpfile p config/profiles.json \
	  '($$p[0].profiles | INDEX(.key)) as $$z | $$a[0].apps[] | select(.needs? == "tailnet") | . as $$app \
	   | (.profiles // [])[] | . as $$k | ($$z[$$k].vpn // "") as $$vpn \
	   | select(($$vpn | startswith("tailscale")) | not) \
	   | "  \($$app.label) is in \($$k), whose VPN slot is \($$vpn)"'); \
	  [ -z "$$unreachable" ] || { echo "apps that need the private tailnet, in zones that cannot reach it:"; \
	    echo "$$unreachable"; echo "  a zone has ONE always-on VPN slot - see docs/architecture/zones.md"; exit 1; }; \
	  echo "ok: tailnet reachability"
	@stray=$$(jq -r -n --slurpfile a config/apps.json --slurpfile p config/profiles.json \
	  '$$p[0].profiles[] | select(.browser) | . as $$z \
	   | select([ $$a[0].apps[] | select(.pkg == $$z.browser) | (.profiles // [])[] | select(. == $$z.key) ] | length == 0) \
	   | "  \($$z.label): browser \($$z.browser) is not placed in this zone"'); \
	  [ -z "$$stray" ] || { echo "zone browsers the catalog does not install there:"; echo "$$stray"; exit 1; }; \
	  echo "ok: zone browsers"
	@lib/readback-compare.test.sh > /dev/null && echo "ok: read-back comparison"
	@config/check-schema.sh
	@pkg=$$(jq -r --arg k "$$(jq -r .launcher config/theming.json)" '.launchers[$$k].pkg' config/theming.json); \
	  bad=$$(for f in config/launcher/*.json; do \
	    z=$$(basename $$f .json); \
	    jq -e '.search.contacts == true' $$f >/dev/null || continue; \
	    jq -e --arg z "$$z" --arg p "$$pkg" '[.apps[] | select(.pkg == $$p) \
	       | select((.perms.grant // []) | index("android.permission.READ_CONTACTS")) \
	       | select(((.perms.only_profiles // .profiles) | index($$z)) != null)] | length > 0' \
	       config/apps.json >/dev/null || echo "  $$z"; \
	  done); \
	  [ -z "$$bad" ] || { echo "search.contacts is true in zones the catalog denies READ_CONTACTS:"; echo "$$bad"; \
	    echo "  the launcher accepts it and shows a Grant banner under every query (andashi/home#140)"; exit 1; }; \
	  echo "ok: contact search only where the permission is"
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

manual: ## Regenerate MANUAL.md
	@provision/90-manual.sh

update: ## Fetch newer APKs, verify them, bring every zone to them
	@apks/fetch.sh
	@apks/verify.sh
	@provision/run.sh

apks: ## Verify APK hashes + signer certs (offline)
	@apks/verify.sh

provenance: ## Re-audit where each pinned signer comes from (needs network)
	@apks/provenance.sh

emulator: ## Check emulator prerequisites
	@emulator/build.sh prereqs

.PHONY: help check todo obtainium launcher-config manual update apks provenance emulator

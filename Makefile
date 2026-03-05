VERSION ?=
NOTES ?=

.PHONY: release
release:
	@if [ -z "$(VERSION)" ]; then \
		echo "Usage: make release VERSION=vX.Y.Z [NOTES='release notes']"; \
		exit 1; \
	fi
	@if [ -n "$(NOTES)" ]; then \
		./scripts/release-all.sh "$(VERSION)" "$(NOTES)"; \
	else \
		./scripts/release-all.sh "$(VERSION)"; \
	fi

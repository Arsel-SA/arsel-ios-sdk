# One entry point for CI and for a Mac checkout.
#
# The Linux toolchain can build and test `Core/` (Foundation-only by design),
# but `Platform/` is behind `#if canImport(UIKit)` and only exists on a real
# iOS build — so `swift test` alone never executes the notification-delegate
# glue. Everything here targets an iOS Simulator for that reason.

SCHEME        = Arsel-Package
SAMPLE_DIR    = Examples/Sample
SAMPLE_PROJ   = ArselSample.xcodeproj
SAMPLE_SCHEME = ArselSample-Staging

# `xcodebuild test` needs a bootable destination, and a hardcoded device name
# rots: simulator runtimes track the SDK, so "iPhone 15" is absent on an Xcode
# 26 image and "iPhone 17" is absent on an Xcode 15 one. Resolve one at runtime
# instead. (Borrowed from klaviyo-swift-sdk, which needs one command to work
# across three Xcodes.)
SIM_ID = $(call udid_for,iOS,iPhone)

default: test

## Unit tests on an iOS Simulator. The only place Platform/ is compiled AND run.
test: require-simulator
	xcodebuild test \
		-scheme $(SCHEME) \
		-destination "platform=iOS Simulator,id=$(SIM_ID)" \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO

## Compile-only build of the package for the simulator, no tests.
build:
	xcodebuild build \
		-scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO

## Delivers a real push to the sample app on a booted simulator and asserts the SDK handled it.
## `simctl push` bypasses APNs, so this needs no signing key, no device and no Apple membership.
# -derivedDataPath is resolved relative to the `cd` in the recipe, so it is `.build`
# and not $(SAMPLE_DIR)/.build — the latter nests as Examples/Sample/Examples/Sample
# and leaves the install step below looking at a path that was never written.
# Split from push-smoke so CI can run the script itself and see its real exit code: make
# collapses every recipe failure to 2, which would erase the script's 78 "skipped".
push-smoke-install: require-simulator
	cd $(SAMPLE_DIR) && xcodegen generate
	cd $(SAMPLE_DIR) && xcodebuild build \
		-project $(SAMPLE_PROJ) \
		-scheme $(SAMPLE_SCHEME) \
		-configuration Debug-Staging \
		-destination "platform=iOS Simulator,id=$(SIM_ID)" \
		-derivedDataPath .build \
		CODE_SIGNING_ALLOWED=NO
	xcrun simctl boot $(SIM_ID) 2>/dev/null || true
	xcrun simctl install $(SIM_ID) \
		$(SAMPLE_DIR)/.build/Build/Products/Debug-Staging-iphonesimulator/ArselSample.app

push-smoke: push-smoke-install
	Scripts/push-smoke.sh

## The harness app, built the way an integrator builds it.
sample:
	cd $(SAMPLE_DIR) && xcodegen generate
	cd $(SAMPLE_DIR) && xcodebuild build \
		-project $(SAMPLE_PROJ) \
		-scheme $(SAMPLE_SCHEME) \
		-configuration Debug-Staging \
		-destination 'generic/platform=iOS Simulator' \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO

# Without this an empty match yields `id=`, which xcodebuild reports as an
# unhelpful destination error rather than "you have no simulators".
require-simulator:
	@if [ -z "$(SIM_ID)" ]; then \
		echo "No available iOS Simulator found."; \
		echo "Check: xcrun simctl list devices available"; \
		exit 1; \
	fi

# simctl lists available devices grouped by runtime, oldest first, as
#   iPhone 17 Pro (UDID) (Shutdown)
# so `tail -1` is the newest runtime's last device. Splitting on ()/ puts the
# UDID in field NF-3.
define udid_for
$(shell xcrun simctl list devices available '$(1)' | grep -E '$(2)' | tail -1 | awk -F '[()]' '{ print $$(NF-3) }')
endef

.PHONY: default test build sample push-smoke push-smoke-install require-simulator

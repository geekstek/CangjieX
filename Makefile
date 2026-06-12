PKG := build/CangjieX.pkg
SOURCE_APP := .source/Yahoo! KeyKey.app
SOURCE_BUILD_DIR := build/source
SOURCE_PKG := $(SOURCE_BUILD_DIR)/CangjieX.pkg

.PHONY: build verify check checksum source-app source-build source-verify source-checksum probe-source doctor uninstall clean

build:
	./build.sh

verify: build
	bash ./verify-pkg.sh $(PKG)

check: verify

checksum: verify
	shasum -a 256 $(PKG) > $(PKG).sha256

source-app:
	PROBE_BUILD=1 SOURCE_BUILD_APP="$(SOURCE_APP)" ./tools/probe-upstream-source.sh

source-build: source-app
	BUILD_DIR="$(SOURCE_BUILD_DIR)" SOURCE_APP="$(SOURCE_APP)" INPUT_METHOD_CONNECTION_NAME="CangjieX_1_Connection" ./build.sh

source-verify: source-build
	REQUIRE_ARM64=1 REQUIRE_CANGJIE_DB=1 REQUIRE_ASSOCIATED_PHRASES=1 MAX_LS_MIN_SYSTEM_VERSION=11.0 EXPECTED_INPUT_METHOD_CONNECTION_NAME="CangjieX_1_Connection" bash ./verify-pkg.sh $(SOURCE_PKG)

source-checksum: source-verify
	shasum -a 256 $(SOURCE_PKG) > $(SOURCE_PKG).sha256

probe-source:
	./tools/probe-upstream-source.sh

doctor:
	./tools/doctor.sh

uninstall:
	./uninstall.sh

clean:
	@if [ -e build ]; then \
		if rm -rf build 2>/dev/null; then \
			echo "Removed build"; \
		else \
			stale_build_dir="/tmp/CangjieX-stale-build-$$(date +%Y%m%d%H%M%S)"; \
			mv build "$$stale_build_dir"; \
			echo "Moved build to $$stale_build_dir"; \
		fi \
	fi

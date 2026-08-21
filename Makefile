.PHONY: all build driver sign-app clean run test test-driver test-all install-driver uninstall-driver

APP_NAME       = OpenConnect
DRIVER_NAME    = OpenConnect
DIST_DIR       = dist
APP_BUNDLE     = $(DIST_DIR)/$(APP_NAME).app
DRIVER_BUNDLE  = $(DIST_DIR)/$(DRIVER_NAME).driver

DEPLOY_TARGET  = 13.0
ARCHS          = -arch arm64 -arch x86_64

DRIVER_SRC     = App/OpenConnectDriver/OpenConnectDriver.c
DRIVER_PLIST   = App/OpenConnectDriver/Info.plist

APP_SRC        = $(shell find App/OpenConnectApp -name '*.swift')
APP_PLIST      = App/OpenConnectApp/Info.plist

DSP_INCLUDE    = Core/Sources/OpenConnectDSP/include
DSP_SRC        = $(wildcard Core/Sources/OpenConnectDSP/*.cpp)
DSP_LIB        = $(DIST_DIR)/libOpenConnectDSP.a
DSP_OBJ_DIR    = $(DIST_DIR)/obj

all: driver build

# --- Driver -------------------------------------------------------------------
# A CFBundle loaded by coreaudiod. Deliberately has no dependency on the DSP core:
# everything in this bundle stays trivial because a fault here breaks system audio.
driver: $(DRIVER_BUNDLE)

$(DRIVER_BUNDLE): $(DRIVER_SRC) $(DRIVER_PLIST)
	@mkdir -p $(DRIVER_BUNDLE)/Contents/MacOS $(DRIVER_BUNDLE)/Contents/Resources
	clang -x c -std=c11 $(ARCHS) -mmacosx-version-min=$(DEPLOY_TARGET) \
		-O2 -fno-common -Wall -Wextra -Werror \
		-bundle \
		-framework CoreFoundation -framework CoreAudio \
		-o $(DRIVER_BUNDLE)/Contents/MacOS/$(DRIVER_NAME) $(DRIVER_SRC)
	@cp $(DRIVER_PLIST) $(DRIVER_BUNDLE)/Contents/Info.plist
	@echo "Built $(DRIVER_BUNDLE)"

# --- DSP core -----------------------------------------------------------------
$(DSP_LIB): $(DSP_SRC)
	@mkdir -p $(DSP_OBJ_DIR)
	@for src in $(DSP_SRC); do \
		clang++ -x c++ -std=c++17 $(ARCHS) -mmacosx-version-min=$(DEPLOY_TARGET) \
			-O2 -fno-math-errno -fno-exceptions -fno-rtti -Wall -Wextra \
			-I $(DSP_INCLUDE) -c "$$src" -o "$(DSP_OBJ_DIR)/$$(basename $$src .cpp).o" || exit 1; \
	done
	@libtool -static -o $(DSP_LIB) $(DSP_OBJ_DIR)/*.o
	@echo "Built $(DSP_LIB)"

# --- App ----------------------------------------------------------------------
# Dev builds are native-arch only for speed. Release builds pass UNIVERSAL=1,
# which compiles each slice separately and lipos them together — swiftc, unlike
# clang, cannot emit a multi-architecture binary in one invocation.
APP_ARCHS ?= arm64
ifeq ($(UNIVERSAL),1)
APP_ARCHS = arm64 x86_64
endif

SWIFT_FLAGS = -parse-as-library -O \
	-framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox \
	-framework AVFoundation -framework Accelerate \
	-import-objc-header App/OpenConnectApp/OpenConnect-Bridging-Header.h \
	-I $(DSP_INCLUDE)

build: $(DSP_LIB)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources $(DSP_OBJ_DIR)
	@for arch in $(APP_ARCHS); do \
		echo "  compiling $(APP_NAME) ($$arch)"; \
		swiftc $(SWIFT_FLAGS) -target $$arch-apple-macosx$(DEPLOY_TARGET) \
			-o $(DSP_OBJ_DIR)/$(APP_NAME)-$$arch $(APP_SRC) $(DSP_LIB) -lc++ || exit 1; \
	done
	@lipo -create $(foreach a,$(APP_ARCHS),$(DSP_OBJ_DIR)/$(APP_NAME)-$(a)) \
		-output $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(APP_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	@echo "Built $(APP_BUNDLE) [$(APP_ARCHS)]"
	@$(MAKE) --no-print-directory sign-app

# Sign the app with a real identity whenever one is available.
#
# This is not cosmetic. TCC keys the microphone grant on the code signature, so
# an ad-hoc signature — which changes on every single rebuild — makes macOS
# forget the permission and re-prompt after every build, and orphans the old
# grant in System Settings. Only a stable Designated Requirement fixes that.
sign-app:
	@identity="$${CODE_SIGN_IDENTITY:-$$(security find-identity -v -p codesigning 2>/dev/null \
		| grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/')}"; \
	if [ -n "$$identity" ]; then \
		codesign --force --options runtime --sign "$$identity" --timestamp \
			$(APP_BUNDLE) >/dev/null 2>&1 && \
		echo "Signed $(APP_BUNDLE) with: $$identity"; \
	else \
		echo "WARNING: no Developer ID Application identity; leaving $(APP_BUNDLE) ad-hoc signed."; \
		echo "         macOS will re-ask for microphone access after every rebuild."; \
	fi

# The app carries its own copy of the driver so it can install or update it.
embed-driver: build driver
	@mkdir -p $(APP_BUNDLE)/Contents/Library/Audio/Plug-Ins/HAL
	@rm -rf $(APP_BUNDLE)/Contents/Library/Audio/Plug-Ins/HAL/$(DRIVER_NAME).driver
	@ditto $(DRIVER_BUNDLE) $(APP_BUNDLE)/Contents/Library/Audio/Plug-Ins/HAL/$(DRIVER_NAME).driver
	@echo "Embedded driver into $(APP_BUNDLE)"
	@# Re-sign: embedding nested content after signing invalidates the seal.
	@$(MAKE) --no-print-directory sign-app

test:
	cd Core && swift test

# Loads the driver with dlopen and drives the AudioServerPlugIn vtable directly
# against a fake host, so property dispatch and the IO round trip can be
# verified without sudo, without coreaudiod, and in CI. The script compiles its
# own copy of the driver with the same flags, so it has no bundle prerequisite.
test-driver:
	./tools/driver_harness/build_and_run.sh

test-all: test test-driver

clean:
	rm -rf $(DIST_DIR)
	rm -rf Core/.build
	rm -rf tools/driver_harness/build

run: build
	@open $(APP_BUNDLE)

install-driver:
	@./scripts/install_driver_dev.sh

uninstall-driver:
	@./scripts/uninstall_driver.sh

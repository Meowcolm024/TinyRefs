RUST_MANIFEST := rust/biblatex-bridge/Cargo.toml
RUST_TARGET := rust/biblatex-bridge/target
APP_EXECUTABLE := TinyRefsApp
APP_BUNDLE := .build/TinyRefs.app
export MACOSX_DEPLOYMENT_TARGET ?= 26.0
export SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path)

.PHONY: build bundle cli clean test rust rust-release

build: rust
	swift build

cli: export TINYREFS_RUST_PROFILE := release
cli: rust-release
	swift build -c release --product tinyrefs

bundle: export TINYREFS_RUST_PROFILE := release
bundle: rust-release
	swift build -c release --product "$(APP_EXECUTABLE)"
	@set -eu; \
	bin_path=$$(swift build -c release --show-bin-path); \
	stage=$$(mktemp -d ".build/TinyRefs.XXXXXX"); \
	trap 'rm -R "$$stage"' EXIT; \
	bundle="$$stage/TinyRefs.app"; \
	mkdir -p "$$bundle/Contents/MacOS" "$$bundle/Contents/Resources"; \
	install -m 644 Info.plist "$$bundle/Contents/Info.plist"; \
	install -m 644 Resources/TinyRefs.icns "$$bundle/Contents/Resources/"; \
	install -m 755 "$$bin_path/$(APP_EXECUTABLE)" "$$bundle/Contents/MacOS/$(APP_EXECUTABLE)"; \
	codesign --force --sign - --timestamp=none "$$bundle"; \
	codesign --verify --strict "$$bundle"; \
	if [ -e "$(APP_BUNDLE)" ] || [ -L "$(APP_BUNDLE)" ]; then \
		rm -R "$(APP_BUNDLE)"; \
	fi; \
	mv "$$bundle" "$(APP_BUNDLE)"; \
	printf 'Built %s\n' "$(APP_BUNDLE)"

clean:
	swift package clean
	cargo clean --locked --manifest-path "$(RUST_MANIFEST)" --target-dir "$(RUST_TARGET)"

test: rust
	cargo test --locked --manifest-path "$(RUST_MANIFEST)" --target-dir "$(RUST_TARGET)"
	swift test

rust:
	cargo build --locked --manifest-path "$(RUST_MANIFEST)" --target-dir "$(RUST_TARGET)"

rust-release:
	cargo build --release --locked --manifest-path "$(RUST_MANIFEST)" --target-dir "$(RUST_TARGET)"

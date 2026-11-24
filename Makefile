RUST_MANIFEST := rust/biblatex-bridge/Cargo.toml
RUST_TARGET := rust/biblatex-bridge/target
export MACOSX_DEPLOYMENT_TARGET ?= 14.0

.PHONY: build test rust

build: rust
	swift build

test: rust
	cargo test --locked --manifest-path "$(RUST_MANIFEST)" --target-dir "$(RUST_TARGET)"
	swift test

rust:
	cargo build --locked --manifest-path "$(RUST_MANIFEST)" --target-dir "$(RUST_TARGET)"

#!/usr/bin/env bash
# Build the Bitwarden SDK bridge (bitwarden/) into build/bitwarden/libangl_bitwarden.a, which the
# angl target links. Needs rustup; bitwarden/rust-toolchain.toml pins the compiler the SDK expects.
# The cargo target dir is shared by every Mac-side checkout, so an unchanged crate is a no-op.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
target_dir="${ANGL_CARGO_TARGET_DIR:-$HOME/Library/Caches/angl-build/cargo}"
lib="$target_dir/aarch64-apple-darwin/release/libangl_bitwarden.a"

# The cfg turns any Bitwarden-licensed (non-GPL) SDK crate into a compile error.
(cd "$root/bitwarden" && RUSTFLAGS="--cfg bitwarden_ensure_non_commercial" MACOSX_DEPLOYMENT_TARGET=15.0 \
  cargo build --release --locked --target aarch64-apple-darwin --target-dir "$target_dir")

mkdir -p "$root/build/bitwarden"
if ! cmp -s "$lib" "$root/build/bitwarden/libangl_bitwarden.a"; then cp "$lib" "$root/build/bitwarden/"; fi

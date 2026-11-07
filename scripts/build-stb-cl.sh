#!/usr/bin/env bash
# Build libstb-cl into lib/<os>-<arch>/ with zig cc (cross-compiles every target).
#   scripts/build-stb-cl.sh [os-arch ...]   default: the host
#   STB_CL_SANITIZE=1  build a host binary with ASan/UBSan for fuzzing
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLIBC="2.31"
die() { echo "build-stb-cl.sh: $*" >&2; exit 1; }
command -v zig >/dev/null 2>&1 || die "zig not found"

host_pair() {
  local os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;; *) die "unknown host OS" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;;
    *) die "unknown host arch" ;; esac
  echo "${os}-${arch}"
}

build() {
  local pair=$1 target out flags=(-O2 -shared -fvisibility=hidden -Wall -Wno-unused-function)
  out="${ROOT}/lib/${pair}"; mkdir -p "$out"
  case "$pair" in
    linux-amd64) target="x86_64-linux-gnu.${GLIBC}" ;;
    linux-arm64) target="aarch64-linux-gnu.${GLIBC}" ;;
    darwin-arm64) target="aarch64-macos" ;;
    windows-amd64) target="x86_64-windows-gnu" ;;
    *) die "unsupported os-arch: $pair" ;;
  esac
  echo "==> ${pair} (${target})"
  case "$pair" in
    linux-*) zig cc -target "$target" "${flags[@]}" -lpthread -lm -Wl,-soname,libstb-cl.so \
               -o "$out/libstb-cl.so" "${ROOT}/native/stb-cl.c" ;;
    darwin-*) zig cc -target "$target" "${flags[@]}" -Wl,-install_name,@rpath/libstb-cl.dylib \
               -o "$out/libstb-cl.dylib" "${ROOT}/native/stb-cl.c" ;;
    windows-*) zig cc -target "$target" "${flags[@]}" -o "$out/stb-cl.dll" "${ROOT}/native/stb-cl.c"
               rm -f "$out"/*.lib "$out"/*.pdb ;;
  esac
  ls -la "$out"
}

pairs=("$@"); [[ ${#pairs[@]} -gt 0 ]] || pairs=("$(host_pair)")
for pair in "${pairs[@]}"; do build "$pair"; done

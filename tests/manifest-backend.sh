#!/usr/bin/env bash
# The manifest carries `backend`: the core module a ui_qml app's backend runs
# as. A shell reads the installed manifest to know it must register and load
# that module when the app opens, so the key has to survive bundling: bundle.sh
# writes it, and `lgx add` (which rewrites the manifest) has to keep it.
#
# Usage:  tests/manifest-backend.sh [flake-ref]     (default: the checkout, ".")
set -uo pipefail

FLAKE="${1:-.}"
case "$FLAKE" in
  *:*) ;;
  *)   FLAKE="path:$(cd "$FLAKE" 2>/dev/null && pwd)" || { echo "manifest-backend: no such flake dir: ${1:-.}" >&2; exit 1; } ;;
esac

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
mkdir subject

# A 256x256 PNG: bundle.sh refuses a ui_qml package without one.
python3 - subject/icon.png <<'PY'
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = b"".join(b"\x00" + b"\x40\x80\xc0" * 256 for _ in range(256))
with open(sys.argv[1], "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 256, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY

cat > subject/metadata.json <<'J'
{
  "name": "backend_subject",
  "version": "0.0.1",
  "type": "ui_qml",
  "view": "Main.qml",
  "icon": "icon.png",
  "backend": "backend_subject_backend",
  "dependencies": []
}
J

printf 'import QtQuick\nItem {}\n' > subject/Main.qml

cat > subject/flake.nix <<NIX
{
  inputs.bundler.url = "$FLAKE";
  inputs.nixpkgs.follows = "bundler/nixpkgs";
  inputs.logos-package.follows = "bundler/logos-package";

  outputs = { self, nixpkgs, logos-package, ... }:
    let pkgs = nixpkgs.legacyPackages."$SYSTEM"; in {
      packages."$SYSTEM" = {
        lgx = logos-package.packages."$SYSTEM".lgx;
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "backend_subject";
          version = "0.0.1";
          src = ./.;
          installPhase = "mkdir -p \$out/lib && cp Main.qml \$out/lib/";
        };
      };
    };
}
NIX

nix build "path:$WORK/subject#lgx" -o out-lgxtool || { echo "FAIL could not build the pinned lgx CLI"; exit 1; }
nix bundle --bundler "$FLAKE#portable" "path:$WORK/subject#default" -o out-pkg \
  || { echo "FAIL nix bundle --bundler $FLAKE#portable failed"; exit 1; }

BACKEND="$(out-lgxtool/bin/lgx manifest out-pkg/backend_subject.lgx --json \
  | python3 -c 'import json, sys; print(json.load(sys.stdin).get("backend", ""))')"
if [ "$BACKEND" = "backend_subject_backend" ]; then
  echo "  ok   manifest carries backend: $BACKEND"
else
  echo "  FAIL manifest backend is '$BACKEND', expected 'backend_subject_backend'"
  exit 1
fi

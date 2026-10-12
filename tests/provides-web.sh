#!/usr/bin/env bash
# The manifest keeps `"web": true` on a `provides` entry.
#
# Basecamp lets a basecamp:// link reach the install offer for a package that
# is not installed only when the package's CATALOG entry says the intent is
# published to the web. The catalog copies the .lgx manifest, so the flag has
# to survive bundling: bundle.sh writes it, and every later step that rewrites
# the manifest (`lgx add`) has to keep it.
#
# The subject is a QML-only ui_qml module with three provides entries:
#   web.open       "web": true    -> kept
#   web.withheld   no flag        -> no flag
#   web.string     "web": "true"  -> no flag (a string is not an opt-in)
#
# Usage:  tests/provides-web.sh [flake-ref]     (default: the checkout, ".")
set -uo pipefail

FLAKE="${1:-.}"
case "$FLAKE" in
  *:*) ;;
  *)   FLAKE="path:$(cd "$FLAKE" 2>/dev/null && pwd)" || { echo "provides-web: no such flake dir: ${1:-.}" >&2; exit 1; } ;;
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
  "name": "provides_web_subject",
  "version": "0.0.1",
  "type": "ui_qml",
  "view": "Main.qml",
  "icon": "icon.png",
  "dependencies": [],
  "provides": [
    { "intent": "web.open", "web": true },
    { "intent": "web.withheld" },
    { "intent": "web.string", "web": "true" }
  ]
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
          pname = "provides_web_subject";
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

PROVIDES="$(out-lgxtool/bin/lgx manifest out-pkg/provides_web_subject.lgx --json \
  | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin).get("provides")))')"
echo "provides in the packaged manifest: $PROVIDES"

python3 - "$PROVIDES" <<'PY'
import json, sys
entries = {e["intent"]: e for e in json.loads(sys.argv[1]) or []}
checks = [
    ("web.open keeps \"web\": true", entries.get("web.open", {}).get("web") is True),
    ("web.withheld carries no web flag", "web" not in entries.get("web.withheld", {"web": None})),
    ("web.string carries no web flag", "web" not in entries.get("web.string", {"web": None})),
]
failed = 0
for name, ok in checks:
    print(("  ok   " if ok else "  FAIL ") + name)
    failed += not ok
sys.exit(1 if failed else 0)
PY

#!/usr/bin/env bash
set -euo pipefail

# bundle.sh — Create a single-variant .lgx package from a Nix derivation.
#
# Environment variables (set by the Nix derivation in flake.nix):
#   SRC_DRV       — path to the source derivation (raw lib output, or bundle-dir processed)
#   VARIANT       — target variant name (e.g. linux-amd64, darwin-arm64)
#   PACKAGE_NAME  — base name for the .lgx file
#   METADATA_FILE — path to a JSON file with lgx manifest fields (may contain just {})
#   LIB_EXT       — primary library extension (.dylib or .so)

LIB_DIR="$SRC_DRV/lib"

if [[ ! -d "$LIB_DIR" ]]; then
  echo "error: no lib/ directory found in $SRC_DRV" >&2
  exit 1
fi

# Create the lgx package
lgx create "$PACKAGE_NAME"
LGX_FILE="${PACKAGE_NAME}.lgx"

# Patch the manifest with metadata from the module's metadata.json (read at eval time).
echo "Patching manifest from metadata..."
python3 - "$LGX_FILE" "$METADATA_FILE" <<'PY'
import json, sys, tarfile, io

lgx_path = sys.argv[1]
with open(sys.argv[2]) as f:
    metadata = json.load(f)

if not metadata:
    sys.exit(0)

with tarfile.open(lgx_path, 'r:gz') as tar:
    members = [(m, tar.extractfile(m).read() if m.isfile() else None) for m in tar.getmembers()]

patched = []
for member, data in members:
    if member.name == 'manifest.json':
        manifest = json.loads(data)
        for key in ('name', 'version', 'description', 'author', 'type', 'category', 'dependencies'):
            if metadata.get(key):
                manifest[key] = metadata[key]
        data = json.dumps(manifest, indent=2).encode()
        member.size = len(data)
    patched.append((member, data))

with tarfile.open(lgx_path, 'w:gz', format=tarfile.GNU_FORMAT) as tar:
    for member, data in patched:
        if data is not None:
            tar.addfile(member, io.BytesIO(data))
        else:
            tar.addfile(member)
PY

# Find the main library file.
# Prefer the "main" field from metadata.json if present.
MAIN_FILE=$(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(m.get('main',''))" "$METADATA_FILE")

if [[ -n "$MAIN_FILE" ]]; then
  if [[ -f "$LIB_DIR/$MAIN_FILE" ]]; then
    : # exact match
  elif [[ -f "$LIB_DIR/${MAIN_FILE}${LIB_EXT}" ]]; then
    MAIN_FILE="${MAIN_FILE}${LIB_EXT}"
  else
    echo "error: main file '$MAIN_FILE' from metadata.json not found in $LIB_DIR" >&2
    exit 1
  fi
else
  if [[ "$LIB_EXT" == ".dylib" ]]; then
    MAIN_FILE=$(ls "$LIB_DIR" | grep '\.dylib$' | head -n 1)
  else
    MAIN_FILE=$(ls "$LIB_DIR" | grep '\.so' | head -n 1)
  fi

  if [[ -z "$MAIN_FILE" ]]; then
    MAIN_FILE=$(ls "$LIB_DIR" | head -n 1)
  fi
fi

if [[ -z "$MAIN_FILE" ]]; then
  echo "error: no library files found in $LIB_DIR" >&2
  exit 1
fi

# Resolve symlinks into real copies so lgx (which may not preserve symlinks)
# includes the short-name version aliases (e.g. libicuuc.76.dylib -> libicuuc.76.1.dylib).
STAGE_DIR="$(mktemp -d)"
cp -a "$LIB_DIR/." "$STAGE_DIR/"
chmod -R u+w "$STAGE_DIR" 2>/dev/null || true
find "$STAGE_DIR" -type l | while IFS= read -r link; do
  target="$(readlink -f "$link" 2>/dev/null)" || true
  if [[ -n "$target" && -f "$target" ]]; then
    rm "$link"
    cp "$target" "$link"
  else
    echo "  Warning: removing broken symlink $(basename "$link")"
    rm "$link"
  fi
done

echo "Adding variant $VARIANT to $LGX_FILE (main: $MAIN_FILE)..."
lgx add "$LGX_FILE" \
  --variant "$VARIANT" \
  --files "$STAGE_DIR/." \
  --main "$MAIN_FILE" \
  -y

rm -rf "$STAGE_DIR"

echo "Done: $LGX_FILE"

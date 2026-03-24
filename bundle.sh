#!/usr/bin/env bash
set -euo pipefail

# bundle.sh — Create a single-variant .lgx package from a Nix derivation.
#
# Environment variables (set by the Nix derivation in flake.nix):
#   SRC_DRV       — path to the source derivation (raw lib output, or bundle-dir processed)
#   VARIANT       — target variant name (e.g. linux-amd64-dev, darwin-arm64)
#   PACKAGE_NAME  — base name for the .lgx file
#   METADATA_FILE — path to a JSON file with lgx manifest fields (may contain just {})
#   LIB_EXT       — primary library extension (.dylib or .so)
#   MODULE_SRC    — path to the module source tree (for resolving icon files etc.)
#   EXTRA_DIRS    — newline-separated list of extra directories to bundle alongside lib
#
# Dual-variant mode (optional):
#   DUAL_VARIANT  — set to "1" to add a second (dev) variant
#   DEV_SRC_DRV   — path to the raw (dev) derivation
#   DEV_VARIANT   — dev variant name (e.g. linux-amd64-dev)

LIB_DIR="$SRC_DRV/lib"

if [[ ! -d "$LIB_DIR" ]]; then
  echo "error: no lib/ directory found in $SRC_DRV" >&2
  exit 1
fi

# Create the lgx package
lgx create "$PACKAGE_NAME"
LGX_FILE="${PACKAGE_NAME}.lgx"

# Resolve the icon file from the module source so it can be staged with the variant files.
# Outputs the icon basename (empty if not found) and copies it to ICON_STAGE_FILE.
ICON_STAGE_FILE=""
ICON_BASENAME=""
if [[ -n "${MODULE_SRC:-}" ]]; then
  read -r ICON_BASENAME ICON_STAGE_FILE < <(python3 - "$METADATA_FILE" "$MODULE_SRC" <<'PY'
import json, sys, os

with open(sys.argv[1]) as f:
    metadata = json.load(f)
module_src = sys.argv[2]

icon_value = metadata.get("icon", "")
if not icon_value:
    print(" ")
    sys.exit(0)

# QRC path ":/icons/foo.png" -> strip leading ":/" to get relative path
if icon_value.startswith(":/"):
    rel_path = icon_value[2:]
elif icon_value.startswith(":"):
    rel_path = icon_value[1:].lstrip("/")
else:
    rel_path = icon_value

# Search for the icon file in likely locations within the module source
candidates = [
    os.path.join(module_src, "src", rel_path),
    os.path.join(module_src, rel_path),
]
for candidate in candidates:
    if os.path.isfile(candidate):
        print(f"{os.path.basename(candidate)} {candidate}")
        sys.exit(0)

print(f"Warning: icon file not found for '{icon_value}' in {module_src}", file=sys.stderr)
print(" ")
PY
  )
fi

# Patch the manifest with metadata from the module's metadata.json (read at eval time).
echo "Patching manifest from metadata..."
python3 - "$LGX_FILE" "$METADATA_FILE" "$ICON_BASENAME" <<'PY'
import json, sys, tarfile, io

lgx_path = sys.argv[1]
with open(sys.argv[2]) as f:
    metadata = json.load(f)
icon_basename = sys.argv[3] if len(sys.argv) > 3 else ""

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
        # Set icon to the bundled filename (or keep the raw value if file was not found)
        if icon_basename:
            manifest['icon'] = icon_basename
        elif metadata.get('icon'):
            manifest['icon'] = metadata['icon']
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
if [[ ! -f "$METADATA_FILE" ]]; then
  echo "error: metadata file not found: $METADATA_FILE" >&2
  exit 1
fi

MAIN_FILE=$(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(m.get('main',''))" "$METADATA_FILE")
PKG_TYPE=$(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(m.get('type',''))" "$METADATA_FILE")

if [[ -z "$MAIN_FILE" ]]; then
  echo "error: no 'main' field in metadata.json — cannot determine main library file" >&2
  exit 1
fi

case "$PKG_TYPE" in
  core|ui)
    MAIN_FILE="${MAIN_FILE}${LIB_EXT}"
    ;;
  ui_qml)
    ;;
  *)
    echo "error: unsupported package type '$PKG_TYPE'" >&2
    exit 1
    ;;
esac

if [[ ! -f "$LIB_DIR/$MAIN_FILE" ]]; then
  echo "error: main file '$MAIN_FILE' not found in $LIB_DIR" >&2
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

# Copy extra directories into the staging directory so they ship alongside lib contents.
if [[ -n "${EXTRA_DIRS:-}" ]]; then
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    if [[ -d "$SRC_DRV/$dir" ]]; then
      mkdir -p "$STAGE_DIR/$dir"
      cp -a "$SRC_DRV/$dir/." "$STAGE_DIR/$dir/"
      chmod -R u+w "$STAGE_DIR/$dir" 2>/dev/null || true
      echo "Bundled extra directory: $dir"
    else
      echo "  Warning: extra directory '$dir' not found in $SRC_DRV"
    fi
  done <<< "$EXTRA_DIRS"
fi

# Copy the icon into the staging directory so it ships inside the variant.
if [[ -n "$ICON_STAGE_FILE" && -f "$ICON_STAGE_FILE" ]]; then
  cp "$ICON_STAGE_FILE" "$STAGE_DIR/$ICON_BASENAME"
  echo "Bundled icon: $ICON_BASENAME"
fi

echo "Adding variant $VARIANT to $LGX_FILE (main: $MAIN_FILE)..."
lgx add "$LGX_FILE" \
  --variant "$VARIANT" \
  --files "$STAGE_DIR/." \
  --main "$MAIN_FILE" \
  -y

rm -rf "$STAGE_DIR"

# Dual-variant mode: add the dev variant from the raw (non-bundled) derivation.
if [[ "${DUAL_VARIANT:-}" == "1" && -n "${DEV_SRC_DRV:-}" && -n "${DEV_VARIANT:-}" ]]; then
  DEV_LIB_DIR="$DEV_SRC_DRV/lib"
  if [[ ! -d "$DEV_LIB_DIR" ]]; then
    echo "error: no lib/ directory found in $DEV_SRC_DRV for dev variant" >&2
    exit 1
  fi

  DEV_STAGE_DIR="$(mktemp -d)"
  cp -a "$DEV_LIB_DIR/." "$DEV_STAGE_DIR/"
  chmod -R u+w "$DEV_STAGE_DIR" 2>/dev/null || true

  # Resolve symlinks in dev staging directory
  find "$DEV_STAGE_DIR" -type l | while IFS= read -r link; do
    target="$(readlink -f "$link" 2>/dev/null)" || true
    if [[ -n "$target" && -f "$target" ]]; then
      rm "$link"
      cp "$target" "$link"
    else
      echo "  Warning: removing broken symlink $(basename "$link")"
      rm "$link"
    fi
  done

  # Copy extra directories into dev staging directory
  if [[ -n "${EXTRA_DIRS:-}" ]]; then
    while IFS= read -r dir; do
      [[ -z "$dir" ]] && continue
      if [[ -d "$DEV_SRC_DRV/$dir" ]]; then
        mkdir -p "$DEV_STAGE_DIR/$dir"
        cp -a "$DEV_SRC_DRV/$dir/." "$DEV_STAGE_DIR/$dir/"
        chmod -R u+w "$DEV_STAGE_DIR/$dir" 2>/dev/null || true
      fi
    done <<< "$EXTRA_DIRS"
  fi

  # Copy icon into dev staging directory
  if [[ -n "$ICON_STAGE_FILE" && -f "$ICON_STAGE_FILE" ]]; then
    cp "$ICON_STAGE_FILE" "$DEV_STAGE_DIR/$ICON_BASENAME"
  fi

  echo "Adding dev variant $DEV_VARIANT to $LGX_FILE (main: $MAIN_FILE)..."
  lgx add "$LGX_FILE" \
    --variant "$DEV_VARIANT" \
    --files "$DEV_STAGE_DIR/." \
    --main "$MAIN_FILE" \
    -y

  rm -rf "$DEV_STAGE_DIR"
fi

echo "Done: $LGX_FILE"

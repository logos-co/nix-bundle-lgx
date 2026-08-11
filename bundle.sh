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
  # Command substitution (not process substitution) so a non-zero exit from
  # the validator actually fails the build -- PIPESTATUS does not see through
  # `< <(...)`.
  ICON_RESULT="$(python3 - "$METADATA_FILE" "$MODULE_SRC" <<'PY'
import json, os, struct, sys

with open(sys.argv[1]) as f:
    metadata = json.load(f)
module_src = sys.argv[2]

icon_value = metadata.get("icon", "")
pkg_type = metadata.get("type", "")

SPEC = "  spec:     logos-package/docs/spec.md#icon-contract"

def fail(lines):
    # stdout carries the "basename path" result the shell reads; emit a blank
    # placeholder so the read doesn't block, then die on stderr.
    print(" ")
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)

if not icon_value:
    # UI packages render a tile in the App Manager, sidebar and launcher, so
    # they must ship artwork. Core modules have no such surface.
    if pkg_type == "ui_qml":
        fail(["ERROR: metadata.json is missing 'icon'.",
              "  ui_qml packages must ship a 256x256 PNG icon.",
              SPEC])
    print(" ")
    sys.exit(0)

# Legacy qrc form ":/icons/foo.png" -> strip the prefix.
if icon_value.startswith(":/"):
    rel_path = icon_value[2:]
elif icon_value.startswith(":"):
    rel_path = icon_value[1:].lstrip("/")
else:
    rel_path = icon_value

candidates = [
    os.path.join(module_src, "src", rel_path),
    os.path.join(module_src, rel_path),
]
found = None
for c in candidates:
    if os.path.isfile(c):
        found = c
        break

if not found:
    fail(["ERROR: icon file not found for '%s'." % icon_value,
          "  searched: %s" % ", ".join(candidates),
          SPEC])

# Validate PNG magic + exact dimensions straight out of IHDR. Fixed offsets,
# so this needs no image library and keeps the nix closure free of one. This
# checks DECLARED dimensions only -- it is not a defence against a malicious
# payload, which is the fetch/decode boundary's job.
with open(found, "rb") as f:
    head = f.read(26)

def reject(actual):
    fail(["ERROR: icon does not match the Logos icon standard.",
          "  file:     %s" % found,
          "  expected: PNG, exactly 256x256",
          "  actual:   %s" % actual,
          SPEC])

if head[:8] != b"\x89PNG\r\n\x1a\n":
    reject("not a PNG")

w = struct.unpack(">I", head[16:20])[0]
h = struct.unpack(">I", head[20:24])[0]
if (w, h) != (256, 256):
    reject("PNG, %dx%d" % (w, h))

print("%s %s" % (os.path.basename(found), found))
PY
)" || exit 1
  read -r ICON_BASENAME ICON_STAGE_FILE <<< "$ICON_RESULT"
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
        for key in ('name', 'display_name', 'version', 'description', 'author', 'type', 'category', 'dependencies', 'view'):
            if metadata.get(key):
                manifest[key] = metadata[key]
        # `icon` is deliberately NOT set here. `lgx add --icon` writes the
        # bytes to assets/icon.png and points the manifest at it; overwriting
        # the field from metadata.json would clobber that canonical path with
        # an author-relative one that nothing can resolve.
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

MAIN_FILE=$(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(m.get('main','') or '')" "$METADATA_FILE")
VIEW_FILE=$(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(m.get('view','') or '')" "$METADATA_FILE")
PKG_TYPE=$(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(m.get('type','') or '')" "$METADATA_FILE")

if [[ -z "$PKG_TYPE" ]]; then
  echo "error: metadata.json is missing required 'type' field (expected: core, ui, or ui_qml)" >&2
  exit 1
fi

case "$PKG_TYPE" in
  core|ui)
    if [[ -z "$MAIN_FILE" ]]; then
      echo "error: no 'main' field in metadata.json — cannot determine main library file" >&2
      exit 1
    fi
    MAIN_FILE="${MAIN_FILE}${LIB_EXT}"
    ;;
  ui_qml)
    # ui_qml contract:
    #   - "view" (required) = QML entry point path
    #   - "main" (optional) = backend Qt plugin lib base name
    if [[ -z "$VIEW_FILE" ]]; then
      echo "error: ui_qml module is missing required 'view' field in metadata.json" >&2
      exit 1
    fi
    if [[ -n "$MAIN_FILE" ]]; then
      MAIN_FILE="${MAIN_FILE}${LIB_EXT}"
    fi
    ;;
  *)
    echo "error: unsupported package type '$PKG_TYPE'" >&2
    exit 1
    ;;
esac

if [[ -n "$MAIN_FILE" && ! -f "$LIB_DIR/$MAIN_FILE" ]]; then
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
# The icon is NOT staged into the variant — at manifest 0.4.0 it lives once at
# the package root (assets/icon.png) so it is variant-independent and readable
# without unpacking a platform build. `lgx add --icon` places it there.
if [[ -n "$ICON_STAGE_FILE" && -f "$ICON_STAGE_FILE" ]]; then
  echo "Bundling icon: $ICON_BASENAME -> assets/icon.png"
fi

if [[ "$PKG_TYPE" == "ui_qml" ]]; then
  if [[ "$VIEW_FILE" = /* || "$VIEW_FILE" == ".." || "$VIEW_FILE" == ../* || "$VIEW_FILE" == */../* || "$VIEW_FILE" == */.. ]]; then
    echo "error: view path '$VIEW_FILE' must be a relative path without '..' segments" >&2
    exit 1
  fi

  resolved_stage="$(cd "$STAGE_DIR" && pwd -P)"
  resolved_view="$(cd "$STAGE_DIR" && realpath -m "$VIEW_FILE" 2>/dev/null)" || resolved_view=""
  if [[ -z "$resolved_view" || "$resolved_view" != "$resolved_stage/"* || ! -f "$STAGE_DIR/$VIEW_FILE" ]]; then
    echo "error: view file '$VIEW_FILE' not found in staged payload" >&2
    exit 1
  fi
fi

ICON_ARGS=()
if [[ -n "$ICON_STAGE_FILE" && -f "$ICON_STAGE_FILE" ]]; then
  ICON_ARGS=(--icon "$ICON_STAGE_FILE")
fi

if [[ -n "$MAIN_FILE" ]]; then
  echo "Adding variant $VARIANT to $LGX_FILE (main: $MAIN_FILE)..."
  lgx add "$LGX_FILE" \
    --variant "$VARIANT" \
    --files "$STAGE_DIR/." \
    --main "$MAIN_FILE" \
    "${ICON_ARGS[@]+"${ICON_ARGS[@]}"}" \
    -y
else
  echo "Adding variant $VARIANT to $LGX_FILE (no backend main entry)..."
  lgx add "$LGX_FILE" \
    --variant "$VARIANT" \
    --files "$STAGE_DIR/." \
    "${ICON_ARGS[@]+"${ICON_ARGS[@]}"}" \
    -y
fi

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
    :  # icon lives at the package root, not per-variant (see above)
  fi

  if [[ "$PKG_TYPE" == "ui_qml" ]]; then
    resolved_dev_stage="$(cd "$DEV_STAGE_DIR" && pwd -P)"
    resolved_dev_view="$(cd "$DEV_STAGE_DIR" && realpath -m "$VIEW_FILE" 2>/dev/null)" || resolved_dev_view=""
    if [[ -z "$resolved_dev_view" || "$resolved_dev_view" != "$resolved_dev_stage/"* || ! -f "$DEV_STAGE_DIR/$VIEW_FILE" ]]; then
      echo "error: view file '$VIEW_FILE' not found in staged dev payload" >&2
      exit 1
    fi
  fi

  if [[ -n "$MAIN_FILE" ]]; then
    echo "Adding dev variant $DEV_VARIANT to $LGX_FILE (main: $MAIN_FILE)..."
    lgx add "$LGX_FILE" \
      --variant "$DEV_VARIANT" \
      --files "$DEV_STAGE_DIR/." \
      --main "$MAIN_FILE" \
      "${ICON_ARGS[@]+"${ICON_ARGS[@]}"}" \
      -y
  else
    echo "Adding dev variant $DEV_VARIANT to $LGX_FILE (no backend main entry)..."
    lgx add "$LGX_FILE" \
      --variant "$DEV_VARIANT" \
      --files "$DEV_STAGE_DIR/." \
      "${ICON_ARGS[@]+"${ICON_ARGS[@]}"}" \
      -y
  fi

  rm -rf "$DEV_STAGE_DIR"
fi

echo "Done: $LGX_FILE"

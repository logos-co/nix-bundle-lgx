#!/usr/bin/env bash
# Smoke test for the .lgx packaging contract on Linux.
#
# `nix build` proves this repo evaluates.  It proves nothing about the thing a
# user actually receives: a gzipped tar whose payload has to run on a machine
# that has never heard of /nix.  A .lgx records NO nix closure -- it is a tar,
# so Nix tracks zero references -- which means every library the payload needs
# either travels inside it or is provided by the host app.  Nothing in the
# build catches a payload that unpacks fine and then cannot exec.
#
# So this builds a deliberately tiny subject, packages it, verifies it,
# unpacks it, asserts what came out, and then runs it on two distros that are
# not the build host.  That last step is the whole point.
#
# The subject is generated here rather than committed: the bundler needs a drv
# carrying a metadata.json (nothing in nixpkgs has one), and generating it
# keeps this script usable against a remote flake ref.  It ships:
#
#   lib/libsmokelgx.so     the "module" -- metadata.json's `main`
#   lib/smokelgx_probe     an executable that dlopen()s the module beside it
#   bin/smokelgx_probe     same binary; bin/ has to hold an ELF or the shim
#                          assertion below asserts nothing (see there)
#   decoy/libsmokelgx.so   same soname, wrong answer; never packaged
#
# The probe lives in lib/ because lib/ IS the .lgx payload: bundle.sh ships
# $SRC_DRV/lib plus extraDirs, and no consumer sets extraDirs to bin.  Its
# dlopen of a bare soname is what the whole layout rests on -- flattened into
# the payload root, the module is found only through the probe's own RPATH.
#
# Every assertion in the two sections that matter -- payload contract, and the
# cross-distro run -- was checked against the previous nix-bundle-dir pin
# (4937262, the ld.so trampoline) and fails there; 10 of 14.  The four that
# pass on both pins are marked as preconditions where they appear.  Checks
# that could only ever pass were deliberately left out: a payload cannot
# contain a launcher, a companion .elf or a nixpkgs `-wrapped` wrapper while
# lib/ is all this repo ships, so asserting their absence would only look like
# coverage.
#
# Usage:  tests/smoke.sh [flake-ref]     (default: the checkout, ".")
set -uo pipefail

FLAKE="${1:-.}"
# Absolutise a local flake ref before we cd into the scratch dir, or `.` would
# resolve to the scratch dir and nix would report "could not find a flake.nix".
# A ref containing ':' is a URL (github:, git+https:, path:) and is left alone.
case "$FLAKE" in
  *:*) ;;
  *)   FLAKE="$(cd "$FLAKE" 2>/dev/null && pwd)" || { echo "smoke: no such flake dir: ${1:-.}" >&2; exit 1; } ;;
esac

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; fail=$((fail+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "${3:-}"; fi; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; echo; echo "== aborted =="; exit 1; }

# Everything below is about ELF, so say so plainly rather than failing oddly
# on a Mac (where an Intel host would otherwise pass the arch check).
[ "$(uname -s)" = "Linux" ] || { echo "smoke: Linux-only; nothing to assert on $(uname -s)"; exit 0; }

# The loader path this architecture's psABI mandates, and the variant name
# bundle.sh derives from the same fact.  Deliberately not a single prefix:
# /lib64/ld-linux-aarch64.so.1 does not exist on current Fedora or openSUSE,
# so "just use /lib64" breaks arm64.
case "$(uname -m)" in
  x86_64)  PSABI=/lib64/ld-linux-x86-64.so.2 ; VARIANT=linux-amd64 ;;
  aarch64) PSABI=/lib/ld-linux-aarch64.so.1  ; VARIANT=linux-arm64 ;;
  *) echo "smoke: unsupported arch $(uname -m); nothing to assert"; exit 0 ;;
esac

interp()   { patchelf --print-interpreter "$1" 2>/dev/null; }
have_tag() { readelf -d "$1" 2>/dev/null | grep -q "($2)"; }

# ---------------------------------------------------------------------------
# The subject
# ---------------------------------------------------------------------------
SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)" || die "nix eval failed"
mkdir -p subject

cat > subject/module.c <<'C'
int smokelgx_answer(void) { return 42; }
C

# Same soname, wrong answer. Never enters the package; it is mounted on
# LD_LIBRARY_PATH in the container to prove the payload ignores it.
cat > subject/decoy.c <<'C'
int smokelgx_answer(void) { return 7; }
C

cat > subject/probe.c <<'C'
#include <dlfcn.h>
#include <stdio.h>

/* Loads the module by bare soname, exactly as a host app does. The payload is
   flat -- module and probe sit in the same directory -- so this resolves only
   through the probe's own DT_RPATH. */
int main(void) {
    void *h = dlopen("libsmokelgx.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int (*answer)(void) = (int (*)(void))dlsym(h, "smokelgx_answer");
    if (!answer) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 2; }
    printf("smokelgx ok %d\n", answer());
    return answer() == 42 ? 0 : 3;
}
C

cat > subject/metadata.json <<'J'
{
  "name": "smokelgx",
  "version": "0.0.1",
  "description": "tiny subject for the nix-bundle-lgx smoke test",
  "author": "smoke",
  "type": "core",
  "main": "libsmokelgx"
}
J

# The subject follows the bundler's own nixpkgs and logos-package, so the
# compiler that builds it and the `lgx` that inspects it are the exact ones
# this repo pins -- no registry, no second nixpkgs to fetch.
cat > subject/flake.nix <<NIX
{
  inputs.bundler.url = "$FLAKE";
  inputs.nixpkgs.follows = "bundler/nixpkgs";
  inputs.logos-package.follows = "bundler/logos-package";

  outputs = { self, nixpkgs, logos-package, ... }:
    let
      system = "$SYSTEM";
      pkgs = nixpkgs.legacyPackages.\${system};
    in {
      packages.\${system} = {
        lgx = logos-package.packages.\${system}.lgx;
        default = pkgs.stdenv.mkDerivation {
          pname = "smokelgx";
          version = "0.0.1";
          src = ./.;
          buildPhase = ''
            \$CC -O2 -shared -fPIC -o libsmokelgx.so module.c
            \$CC -O2 -shared -fPIC -o decoy.so decoy.c
            \$CC -O2 -o smokelgx_probe probe.c -ldl
          '';
          # decoy/ is neither bin/ nor lib/, so no bundler ever copies it and
          # it cannot leak into the package.
          installPhase = ''
            mkdir -p \$out/lib \$out/bin \$out/decoy
            cp libsmokelgx.so smokelgx_probe \$out/lib/
            cp smokelgx_probe \$out/bin/
            cp decoy.so \$out/decoy/libsmokelgx.so
          '';
        };
      };
    };
}
NIX

echo "== building =="
nix build "path:$WORK/subject#lgx" -o out-lgxtool || die "could not build the pinned lgx CLI"
LGX="$(readlink -f out-lgxtool)/bin/lgx"
nix build "path:$WORK/subject#default" -o out-subject || die "the subject does not build"
nix bundle --bundler "$FLAKE#portable" "path:$WORK/subject#default" -o out-pkg \
  || die "nix bundle --bundler $FLAKE#portable failed"
PKG="$(readlink -f out-pkg)/smokelgx.lgx"
[ -f "$PKG" ] || die "no smokelgx.lgx in the bundler output: $(ls "$(readlink -f out-pkg)")"

echo
echo "== the package (preconditions, not bump-sensitive) =="
# These four say the package exists and holds what it claims. They pass on
# either pin -- they guard this repo's own code and the `lgx` it pins, not the
# bundler bump -- but without them a broken payload would fail the assertions
# below for the wrong reason, or the whole file would assert nothing at all.
"$LGX" verify "$PKG" || die "lgx verify rejected the package it just built"
ok "lgx verify"
"$LGX" extract "$PKG" -v "$VARIANT" -o payload >/dev/null || die "lgx extract -v $VARIANT failed"
# lgx may unpack into payload/ or payload/<variant>/; find the module either way.
P="$(dirname "$(find payload -name libsmokelgx.so -print -quit)")"
[ -n "$P" ] && [ -d "$P" ] || die "extracted payload has no libsmokelgx.so: $(find payload -type f | head)"
ok "the payload carries the module named by metadata.json"
PROBE="$P/smokelgx_probe"
check "the payload carries the probe next to the module" "[ -f '$PROBE' ]"
check "the probe kept its executable bit through the tar" "[ -x '$PROBE' ]"

echo
echo "== payload contract (each of these fails on the previous pin) =="
for f in "$PROBE" "$P/libsmokelgx.so"; do
  n="$(basename "$f")"
  check "$n: DT_RPATH is set (bundled libs beat a stale LD_LIBRARY_PATH)" \
        "have_tag '$f' RPATH"
  check "$n: DT_RUNPATH is NOT set (it loses to LD_LIBRARY_PATH)" \
        "! have_tag '$f' RUNPATH" \
        "DT_RUNPATH is what patchelf writes without --force-rpath"
done
check "probe PT_INTERP is the psABI path ($PSABI)" \
      "[ \"\$(interp '$PROBE')\" = '$PSABI' ]" \
      "got: $(interp "$PROBE")"
# The LD_PRELOAD shim existed only to fake readlink(/proc/self/exe) for the old
# ld.so trampoline. It was built into lib/ -- which IS the .lgx payload -- so
# every package shipped it to users, whether or not anything loaded it.
check "no libprocself_fix.so in the payload" \
      "! find payload -name 'libprocself_fix.so' | grep -q ." \
      "the LD_PRELOAD shim is dead weight inside every package that carries it"

echo
echo "== runs on distros that are not the build host =="
# The point of the whole exercise. A payload that unpacks cleanly and then
# cannot exec is the failure this repo ships to users, and it is invisible to
# `nix build` -- the build host has /nix/store, so everything works there.
#
# Each image runs the probe twice. The second run puts a DECOY libsmokelgx.so
# (same soname, answers 7) on LD_LIBRARY_PATH, which is how the payload's
# RPATH earns its keep: for a bare dlopen the loader consults DT_RPATH BEFORE
# LD_LIBRARY_PATH but LD_LIBRARY_PATH before DT_RUNPATH. A payload linked with
# RUNPATH silently loads the stranger's library and answers 7.
# Match on a line, not on the whole capture: the first `docker run` of an
# image that is not yet local pulls it, and that progress lands on the same
# combined stream. Exact equality then fails even though the probe printed
# the right answer — which is exactly how this failed in CI (images cached
# on the server where it was developed, cold on the runner). Same shape as
# nix-bundle-appimage's run_in.
probe_ok() {  # probe_ok <label> <docker-run args...>
  local label="$1" out rc; shift
  out="$(docker run "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 'smokelgx ok 42'; then
    ok "$label"
  else
    bad "$label" "exit $rc: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"
  fi
}
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ABS="$(cd "$P" && pwd)"
  DECOY="$(readlink -f out-subject)/decoy"
  for img in ubuntu:latest fedora:latest; do
    probe_ok "$img: probe ran and dlopened the module" \
      --rm -v "$ABS:/p:ro" "$img" /p/smokelgx_probe
    # Second run: decoy of the same soname on LD_LIBRARY_PATH. With DT_RPATH
    # the payload keeps its own module; with DT_RUNPATH the decoy wins and
    # the probe prints 7 instead of 42.
    probe_ok "$img: kept its own module with a decoy on LD_LIBRARY_PATH" \
      --rm -v "$ABS:/p:ro" -v "$DECOY:/decoy:ro" -e LD_LIBRARY_PATH=/decoy \
      "$img" /p/smokelgx_probe
  done
else
  echo "  -- docker unavailable, skipping the cross-distro run"
  echo "     (the payload assertions above still ran; portability did not)"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]

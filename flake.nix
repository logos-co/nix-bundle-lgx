{
  description = "Bundle Nix derivations into LGX packages (dev, portable, or dual-variant)";

  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
    logos-package.url = "github:logos-co/logos-package";
    nix-bundle-dir.url = "github:logos-co/nix-bundle-dir";
  };

  outputs = { self, nixpkgs, logos-nix, logos-package, nix-bundle-dir }:
    let
      # The BUILD platform for a given target. `lgx` and nix-bundle-dir are
      # tools that RUN during the build, so on a cross target they must come
      # from the build system -- taking them from `packages.x86_64-windows`
      # would hand the builder a PE it cannot execute. (Same host-tool /
      # target-artifact split as logos-cpp-sdk's generator.)
      buildSystemFor = target:
        if target == "x86_64-windows" then "x86_64-linux" else target;

      forAllSystems = f: logos-nix.lib.forAllTargets ({ system, pkgs }:
        let buildSystem = buildSystemFor system; in f {
          inherit system pkgs;
          lgx = logos-package.packages.${buildSystem}.lgx;
          mkBundleDir = nix-bundle-dir.lib.${buildSystem}.mkBundle;
        });
    in
    {
      bundlers = forAllSystems ({ pkgs, lgx, mkBundleDir, ... }:
        let
          # Windows MUST be tested first. Under a mingw cross set `isDarwin` and
          # `isAarch64` are both false, so a Windows build used to fall through
          # the else-branch and label itself "linux-amd64" -- a Windows .lgx
          # claiming to be a Linux package. lgpm computes "windows-x86_64"
          # (package_manager_lib.cpp currentPlatformVariant) and has no alias
          # fallback for it, so that exact spelling is the contract.
          variantName =
            if pkgs.stdenv.hostPlatform.isWindows then
              (if pkgs.stdenv.hostPlatform.isAarch64 then "windows-arm64" else "windows-x86_64")
            else if pkgs.stdenv.isDarwin then
              (if pkgs.stdenv.isAarch64 then "darwin-arm64" else "darwin-amd64")
            else
              (if pkgs.stdenv.isAarch64 then "linux-arm64" else "linux-amd64");

          devVariantName = variantName + "-dev";

          # nix-bundle-dir's `guiApp` is deliberately not plumbed through.
          # It decides one thing only: whether bin/ entries are replaced by a
          # launcher that exports XKB_CONFIG_ROOT / QT_QPA_PLATFORMTHEME. An
          # .lgx payload is $SRC_DRV/lib plus extraDirs, so bin/ never enters
          # the package and the flag has no observable effect on our output.
          # It would be a knob callers could set and never see. Revisit only if
          # a consumer starts putting "bin" in extraDirs, in which case the
          # default (true) is already the safe direction.
          # On Windows the raw Nix output is ALREADY relocatable, so there is
          # nothing for nix-bundle-dir to do. A PE has no rpath and no
          # interpreter -- imports carry DLL base names only and Windows
          # searches the importing module's directory (given logos-module's
          # LOAD_WITH_ALTERED_SEARCH_PATH pre-load) -- so the path rewriting
          # that nix-bundle-dir exists for (patchelf --set-rpath,
          # install_name_tool) has no Windows analogue. logos-plugin-qt already
          # stages the plugin's transitive DLL closure into $out/lib via
          # linkDLLsInfolder, which is the whole job. bundle.sh is also
          # ELF/Mach-O only (`file -b` -> Mach-O | ELF, no PE branch), so
          # calling it here would silently produce a payload with nothing
          # collected.
          # DLLs the Logos host already ships in its own bin/ (verified against
          # logos_host_qt.exe's staged set). Windows binds an import to a module
          # already loaded under that base name BEFORE searching any directory,
          # so a duplicate here would be inert rather than dangerous -- but
          # linkDLLsInfolder stages the FULL closure, and for capability_module
          # that is every one of these, ~36 MB (Qt6Core alone is 15 MB) of
          # host-provided runtime inside each module package. Dropping them is
          # the Windows spelling of the hostLibs list below, which exists for
          # exactly this reason. Note the Unix globs do NOT transfer: "libz*"
          # never matches "zlib1.dll".
          windowsHostLibs = [
            "Qt*.dll"
            "libcrypto-*.dll" "libssl-*.dll"
            "libstdc++-*.dll" "libgcc_s_*.dll" "libmcfgthread-*.dll"
            "libpcre2-*.dll" "libb2-*.dll" "libdouble-conversion.dll"
            "libzstd.dll" "zlib1.dll"
            "libfmt.dll" "libspdlog.dll"
            "libiconv-*.dll" "libcharset-*.dll" "libintl-*.dll"
            "libicuuc*.dll" "libicui18n*.dll" "libicudata*.dll"
            "liblogos_core*.dll" "liblogos_sdk*.dll" "liblgx*.dll"
          ];

          # Windows payload: the raw output minus host-provided DLLs. Copies the
          # WHOLE tree, not just lib/, because bundle.sh reads extraDirs out of
          # SRC_DRV too. Uses pkgsBuildBuild so this file-shuffling runs on the
          # builder rather than becoming a cross derivation.
          mkWindowsPayload = drv:
            pkgs.pkgsBuildBuild.runCommand "${drv.pname or drv.name or "bundle"}-win-payload" { } ''
              mkdir -p $out
              cp -rL ${drv}/. $out/ 2>/dev/null || true
              chmod -R u+w $out
              if [ -d "$out/lib" ]; then
                for pat in ${nixpkgs.lib.escapeShellArgs windowsHostLibs}; do
                  for f in $out/lib/$pat; do
                    [ -e "$f" ] || continue
                    echo "host-provided, dropping from payload: $(basename "$f")"
                    rm -f "$f"
                  done
                done
              fi
            '';

          mkBundleDirForDrv =
            if pkgs.stdenv.hostPlatform.isWindows then mkWindowsPayload
            else drv: mkBundleDir {
            inherit drv;
            name = drv.pname or drv.name or "bundle";
            extraDirs = drv.extraDirs or [];
            hostLibs = (drv.hostLibs or []) ++ [
              "Qt*"
              "libQt*"
              "liblogos_core*"
              "liblogos_sdk*"
              "libcharset*"
              "libiconv*"
              "libintl*"
              "liblgx*"
              "libz*"
              "libicuuc*"
              "libicui18n*"
              "libicudata*"
            ];
            warnOnBinaryData = true;
          };

          # mode: "dev" (raw nix output, -dev variant), "portable" (bundle-dir, no suffix), "dual" (both)
          mkLgxBundle = { mode ? "dev" }: drv:
            let
              srcDrv =
                if mode == "dev"
                then drv
                else mkBundleDirForDrv drv;

              name = drv.pname or drv.name or "bundle";

              # Read metadata.json from the derivation's source at eval time.
              # drv.src is a store path for the module source (set via `src = ./.` in
              # the module flake), so metadata.json is reachable without a build step.
              metadataJson =
                let
                  result = builtins.tryEval (
                    if drv ? src && builtins.pathExists (drv.src + "/metadata.json")
                    then builtins.readFile (drv.src + "/metadata.json")
                    else "{}"
                  );
                in if result.success then result.value else "{}";

              metadataFile = pkgs.writeText "${name}-metadata.json" metadataJson;

              # Source directory of the module (for resolving icon paths etc.)
              moduleSrc =
                if drv ? src then "${drv.src}" else null;
            in
            pkgs.stdenv.mkDerivation ({
              pname = "${name}-lgx";
              version = drv.version or "0";

              src = null;
              dontUnpack = true;
              dontFixup = true;

              nativeBuildInputs = [ lgx pkgs.python3 ];

              SRC_DRV = "${srcDrv}";
              VARIANT = if mode == "dev" then devVariantName else variantName;
              PACKAGE_NAME = name;
              METADATA_FILE = "${metadataFile}";
              LIB_EXT =
                if pkgs.stdenv.hostPlatform.isWindows then ".dll"
                else if pkgs.stdenv.isDarwin then ".dylib"
                else ".so";
              MODULE_SRC = if moduleSrc != null then moduleSrc else "";
              EXTRA_DIRS = builtins.concatStringsSep "\n" (drv.extraDirs or []);

              buildPhase = ''
                bash ${./bundle.sh}
              '';

              installPhase = ''
                mkdir -p $out
                cp *.lgx $out/
              '';
            } // (if mode == "dual" then {
              # For dual mode, also pass the raw (dev) derivation so bundle.sh
              # can add it as a second variant.
              DEV_SRC_DRV = "${drv}";
              DEV_VARIANT = devVariantName;
              DUAL_VARIANT = "1";
            } else {}));
        in
        {
          # Bundle the lib output as-is with a -dev variant name.
          # Dynamic libraries resolve from /nix/store at runtime.
          default = mkLgxBundle { mode = "dev"; };

          # Apply nix-bundle-dir first to produce a self-contained directory,
          # then wrap it into an lgx package with the portable variant name.
          portable = mkLgxBundle { mode = "portable"; };

          # Produce a dual-variant package containing both portable and dev variants.
          dual = mkLgxBundle { mode = "dual"; };
        });
    };
}

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
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
        lgx = logos-package.packages.${system}.lgx;
        mkBundleDir = nix-bundle-dir.lib.${system}.mkBundle;
      });
    in
    {
      bundlers = forAllSystems ({ pkgs, lgx, mkBundleDir, ... }:
        let
          variantName =
            if pkgs.stdenv.isDarwin then
              (if pkgs.stdenv.isAarch64 then "darwin-arm64" else "darwin-amd64")
            else
              (if pkgs.stdenv.isAarch64 then "linux-arm64" else "linux-amd64");

          devVariantName = variantName + "-dev";

          mkBundleDirForDrv = drv: mkBundleDir {
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
              LIB_EXT = if pkgs.stdenv.isDarwin then ".dylib" else ".so";
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

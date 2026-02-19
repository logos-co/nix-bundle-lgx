{
  description = "Bundle Nix derivations into single-variant LGX packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    logos-package.url = "github:logos-co/logos-package";
    nix-bundle-dir.url = "github:logos-co/nix-bundle-dir";
  };

  outputs = { self, nixpkgs, logos-package, nix-bundle-dir }:
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

          mkLgxBundle = { portable ? false }: drv:
            let
              srcDrv =
                if portable
                then mkBundleDir {
                  inherit drv;
                  name = drv.pname or drv.name or "bundle";
                  extraDirs = drv.extraDirs or [];
                  hostLibs = (drv.hostLibs or []) ++ [ "Qt*" ];
                  warnOnBinaryData = true;
                }
                else drv;

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
            in
            pkgs.stdenv.mkDerivation {
              pname = "${name}-lgx";
              version = drv.version or "0";

              src = null;
              dontUnpack = true;
              dontFixup = true;

              nativeBuildInputs = [ lgx pkgs.python3 ];

              SRC_DRV = "${srcDrv}";
              VARIANT = variantName;
              PACKAGE_NAME = name;
              METADATA_FILE = "${metadataFile}";
              LIB_EXT = if pkgs.stdenv.isDarwin then ".dylib" else ".so";

              buildPhase = ''
                bash ${./bundle.sh}
              '';

              installPhase = ''
                mkdir -p $out
                cp *.lgx $out/
              '';
            };
        in
        {
          # Bundle the lib output as-is; dynamic libraries are resolved from /nix/store at runtime.
          default = mkLgxBundle {};

          # Apply nix-bundle-dir#qtPlugin first to produce a self-contained directory,
          # then wrap it into an lgx package.
          portable = mkLgxBundle { portable = true; };
        });
    };
}

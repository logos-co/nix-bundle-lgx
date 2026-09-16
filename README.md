# nix-bundle-lgx

A [Nix bundler](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-bundle.html) that packages a derivation's `lib/` output into a single-variant `.lgx` file.

## Bundlers

### `#default` (dev)

Wraps the derivation's `lib/` directory directly into an `.lgx` package with a **dev variant** (`-dev` suffix). Dynamic libraries are **not** relocated — they continue to resolve dependencies from `/nix/store` at runtime. Suitable for environments where the Nix store is available. The bundle's output depends on the derivation (see [Output](#output)), so fetching the bundle from a binary cache also fetches the store paths the payload loads.

```bash
nix bundle --bundler github:logos-co/nix-bundle-lgx .#lib
```

### `#portable`

First passes the derivation through [`nix-bundle-dir#qtPlugin`](https://github.com/logos-co/nix-bundle-dir), which copies all non-system/non-Qt transitive dependencies alongside the library and rewrites their rpaths to use `@loader_path` (macOS) or `$ORIGIN` (Linux). The resulting self-contained directory is then wrapped into an `.lgx` package with the **portable variant** (no suffix).

```bash
nix bundle --bundler github:logos-co/nix-bundle-lgx#portable .#lib
```

### `#dual`

Produces a **dual-variant** `.lgx` package containing both the portable variant and the dev variant. The portable variant is created via `nix-bundle-dir` (self-contained), while the dev variant uses the raw derivation output (resolves from `/nix/store`). Useful for distributing a single package that works in both dev and portable environments.

```bash
nix bundle --bundler github:logos-co/nix-bundle-lgx#dual .#lib
```

## Variant Names

Each bundler mode produces variants with specific naming:

| Nix system        | Dev variant (`#default`) | Portable variant (`#portable`) |
|-------------------|--------------------------|-------------------------------|
| `aarch64-darwin`  | `darwin-arm64-dev`       | `darwin-arm64`                |
| `x86_64-darwin`   | `darwin-amd64-dev`       | `darwin-amd64`                |
| `aarch64-linux`   | `linux-arm64-dev`        | `linux-arm64`                 |
| `x86_64-linux`    | `linux-amd64-dev`        | `linux-amd64`                 |

The `#dual` bundler includes both the portable and dev variant names in a single `.lgx` file.

## Output

All bundlers produce a single `.lgx` file placed in `$out/`. When invoked via `nix bundle -o result`, the result symlink points to that directory. Find the package with a `*.lgx` pattern rather than taking every entry in `$out/`.

The `#default` and `#dual` bundlers also write `$out/nix-support/lgx-payload-closure`, which contains the store path of the raw derivation. The `.lgx` is compressed, so Nix cannot see the store paths inside it; this file is what makes Nix record the dev payload and its runtime closure as dependencies of the output. `#portable` bundles and Windows bundles do not write it, because their payloads load nothing from `/nix/store`.

## Platform-independent assets

A derivation can publish directories that belong once at the package root,
outside every platform variant, through the `lgxAssets` passthru attribute. The
attribute maps the destination below `assets/` to a directory relative to the
derivation output:

```nix
passthru.lgxAssets = {
  lidl = "share/logos";
};
```

That mapping places `$out/share/logos/*.lidl` at
`assets/lidl/*.lidl` in the `.lgx`. Portable and dual bundles preserve these
directories through the relocation pass but do not copy them into the variant
payload. If multiple mappings or merged platform packages provide the same
asset path, byte-identical files are deduplicated and differing content fails
the build.

## Metadata

The bundler reads `metadata.json` from the derivation's **source tree** (`drv.src`) at Nix eval time — not from the build output. If `metadata.json` is found, the fields `name`, `version`, `description`, `author`, `type`, `category`, `dependencies`, and `view` are patched into the `.lgx` manifest automatically. If not found, the bundler falls back to an empty `{}`.

`metadata.json` is not required in the derivation output (`$out/`) for `core` or `ui` modules.

For `type == "ui_qml"`:
- `view` is required and points to the QML entry file bundled inside each variant
- `main` is optional and, when present, is treated as the backend plugin base name
- QML-only packages are emitted without synthesizing `main = view`

## Expected derivation layout

The bundler expects the input derivation to expose a `lib/` subdirectory containing the shared library (`.dylib` on macOS, `.so` on Linux). This matches the `#lib` output convention used by Logos modules.

```
$out/
  lib/
    libfoo.dylib   # or libfoo.so
  share/logos/     # optional canonical LIDL contracts
    foo.lidl
  metadata.json    # optional
```

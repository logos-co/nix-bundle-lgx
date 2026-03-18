# nix-bundle-lgx

A [Nix bundler](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-bundle.html) that packages a derivation's `lib/` output into a single-variant `.lgx` file.

## Bundlers

### `#default` (dev)

Wraps the derivation's `lib/` directory directly into an `.lgx` package with a **dev variant** (`-dev` suffix). Dynamic libraries are **not** relocated — they continue to resolve dependencies from `/nix/store` at runtime. Suitable for environments where the Nix store is available.

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

All bundlers produce a single `.lgx` file placed in `$out/`. When invoked via `nix bundle -o result`, the result symlink points to that directory.

## Metadata

If the derivation's output contains a `metadata.json` at its root, the fields `name`, `version`, `description`, `author`, `type`, `category`, and `dependencies` are patched into the `.lgx` manifest automatically.

## Expected derivation layout

The bundler expects the input derivation to expose a `lib/` subdirectory containing the shared library (`.dylib` on macOS, `.so` on Linux). This matches the `#lib` output convention used by Logos modules.

```
$out/
  lib/
    libfoo.dylib   # or libfoo.so
  metadata.json    # optional
```

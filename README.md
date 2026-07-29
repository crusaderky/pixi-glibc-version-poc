# pixi-glibc-version-poc

Minimal reproducer: **a `pixi-build` recipe cannot raise the glibc version of the
sysroot it compiles against.**

`stdlib('c')` is hard-pinned to `sysroot_linux-64 =2.28` by pixi, the recipe's own
`variants.yaml` cannot override it, and the `glibc` system requirement declared in
`pixi.toml` does not reach the build solve. Source that needs a newer glibc
therefore cannot be built, on any host, regardless of the host's actual glibc.

## Reproduce

```bash
pixi build
```

## What happens

```
================================================================
what the recipe asked for vs. what it got
================================================================
variants.yaml control_key ....... variants.yaml-was-read
variants.yaml c_stdlib_version .. 2.34  (as written in the file)
resolved c_stdlib_version ....... 2.28
resolved stdlib('c') ............ sysroot_linux-64 =2.28
pixi.toml glibc system req ...... 2.34  (as written in the file)

sysroot ......................... $BUILD_PREFIX/x86_64-conda-linux-gnu/sysroot
sysroot glibc ................... 2.28
addchdir_np declared in sysroot . NO  <-- the compile below cannot succeed
================================================================

needs_glibc_229.c: In function 'main':
needs_glibc_229.c:26:9: error: implicit declaration of function
    'posix_spawn_file_actions_addchdir_np'; did you mean
    'posix_spawn_file_actions_adddup2'? [-Werror=implicit-function-declaration]
   26 |     if (posix_spawn_file_actions_addchdir_np(&actions, "/tmp") != 0) {
      |         ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
× error Script failed with status 1
```

`src/needs_glibc_229.c` calls `posix_spawn_file_actions_addchdir_np()`, added in
**glibc 2.29**. There is no way to reach it with an older sysroot: the declaration
is absent from `<spawn.h>` and the symbol is absent from the sysroot's libc, so
neither a local prototype nor a link-time trick helps. Conda's gcc is built with
`--with-sysroot`, so the host's `/usr/include` never enters the search path:

```
$ x86_64-conda-linux-gnu-gcc -print-sysroot
.../bld/x86_64-conda-linux-gnu/sysroot
$ echo | x86_64-conda-linux-gnu-gcc -E -Wp,-v -
 .../lib/gcc/x86_64-conda-linux-gnu/15.2.0/include
 .../lib/gcc/x86_64-conda-linux-gnu/15.2.0/include-fixed
 .../x86_64-conda-linux-gnu/sysroot/usr/include     <-- only libc headers
```

## The four ways I tried to ask for a newer glibc

### 1. `glibc` system requirement in `pixi.toml`

```toml
platforms = [{ platform = "linux-64", glibc = "2.34" }]
```

Valid syntax — pixi rejects unknown keys here with *"Unexpected keys, expected
only `name`, `platform`, `cuda`, `archspec`, `glibc`, `linux`, `macos`, `osx`,
`windows`"* — but it has no effect on the sysroot, and `__glibc` in the build
solve stays at 2.28 (see attempt 3).

The value is ignored in **both** directions, so this is not a "can't lower the
floor" safety check — the declared requirement simply never reaches the build:

| `glibc` in `pixi.toml` | resolved `stdlib('c')` |
| --- | --- |
| `"2.17"` | `sysroot_linux-64 =2.28` |
| `"2.28"` | `sysroot_linux-64 =2.28` |
| `"2.39"` | `sysroot_linux-64 =2.28` |

(`[system-requirements]` is the older spelling; pixi 0.73 rejects it with
*"declare these on the `platforms` entries instead"*, so the table above is the
current supported form.)

### 2. `stdlib('c')` + `c_stdlib_version` in `variants.yaml`

```yaml
# variants.yaml
c_stdlib_version: ["2.34"]
control_key: ["variants.yaml-was-read"]
```
```yaml
# recipe.yaml
requirements:
  build:
    - ${{ stdlib('c') }}
```

`variants.yaml` **is** read — `control_key` reaches the build script — but
`c_stdlib_version` resolves to `2.28`, not the `2.34` in the file, and
`stdlib('c')` expands to `sysroot_linux-64 =2.28`.

pixi appears to inject `c_stdlib`/`c_stdlib_version` and to have precedence over
the recipe's variant config: `strings` on the `pixi` binary contains
`c_stdlib_version`, while `pixi-build-rattler-build` contains no literal `2.28`
anywhere. Note the injected pin is *exact* (`=2.28`), so a recipe cannot loosen
it either.

### 3. Pinning the sysroot package directly

Uncomment the last line of `recipe.yaml`:

```yaml
requirements:
  build:
    - sysroot_linux-64 2.34.*
```

```
Error:   × failed to solve the build environment for package 'glibc-poc'
  ├─▶ failed to solve the environment
  ╰─▶ Cannot solve the request because of: sysroot_linux-64 2.34.* cannot be
      installed because there are no viable options:
      └─ sysroot_linux-64 2.34 would require
         └─ __glibc >=2.34, for which no candidates were found.
      The following packages are incompatible
      ├─ sysroot_linux-64 2.34.* cannot be installed ...
      └─ sysroot_linux-64 2.28.* cannot be installed ...
```

Both halves of the problem in one message:

1. `__glibc >=2.34` has **no candidates**, i.e. the `glibc = "2.34"` system
   requirement from attempt 1 never reached this solve. The baseline is 2.28 — a
   `sysroot_linux-64 2.28.*` pin resolves fine. (`sysroot_linux-64 2.34`
   *depends on* `__glibc >=2.34`, so the virtual package gates the sysroot.)
2. The explicit `2.34` pin collides head-on with the `=2.28` injected by
   `stdlib('c')`, so attempts 2 and 3 cannot even be combined.

### 4. The backend's own variant config

`[package.build.config]` is the correct table for backend configuration, but on
`pixi-build-rattler-build` 0.4.4 it does not expose the variant config:

```toml
[package.build.config]
variantConfiguration = { c_stdlib_version = ["2.34"] }
```
```
Error:   × could not initialize the build-backend
  ╰─▶   × unknown field `variantConfiguration`, expected one of `debug-dir`,
        │ `debug_dir`, `extra-input-globs`, `experimental`, `recipe`
```

The backend binary *does* carry a `variantConfiguration` field, but it is
protocol-internal — the channel pixi uses to hand its own variant config to the
backend — and is not reachable from the manifest. `experimental = true` is
accepted and changes nothing.

`pixi config` likewise exposes no glibc/stdlib/sysroot/variant setting.

## Where the 2.28 comes from

Not a hardcoded constant in either binary: `pixi-build-rattler-build` contains no
literal `2.28` at all, and in `pixi` the only occurrences are a cargo dependency
path and the `--glibc` CLI help example. `pixi` does contain the `c_stdlib` and
`c_stdlib_version` key names, while the backend contains only the `_stdlib`
format fragments — so pixi composes the variant config and passes it down, and
its value takes precedence over the recipe's `variants.yaml`.

So the pin appears to be derived from pixi's *default* glibc system requirement
for the target platform, with the workspace's declared requirement not consulted
on this path.

## Expected

Some supported way for a recipe (or the workspace) to select the build sysroot —
e.g. `c_stdlib_version` in the recipe's `variants.yaml` being honoured, or the
`glibc` system requirement in `pixi.toml` propagating to the build solve and
raising `__glibc` there.

conda-forge's default sysroot is deliberately old for redistributable packages,
which is the right default; the issue is only that it appears impossible to
override for a local build whose host glibc is far newer.

## Environment

| | |
| --- | --- |
| pixi | 0.73.0 |
| pixi-build-rattler-build | 0.4.4 |
| host | Ubuntu 24.04.4 LTS, glibc 2.39 (declares `posix_spawn_file_actions_addchdir_np`) |
| build sysroot | `sysroot_linux-64` 2.28 |
| compiler | `gcc_linux-64` 15.2.0 |
| channel | `https://prefix.dev/conda-forge` |

## Real-world case

Mainline llama.cpp commit
[`0cea362`](https://github.com/ggml-org/llama.cpp/commit/0cea36222fe9bac5ebfc45716c9eef11f37046c4)
("vendor: update subprocess.h", #26061) updated its vendored
`sheredom/subprocess.h` to implement per-child working directories with
`posix_spawn_file_actions_addchdir_np`, guarded only for Apple with no
`__GLIBC_PREREQ` fallback. Building llama.cpp with `pixi-build` therefore fails
in `common/subproc.cpp` against the 2.28 sysroot, with no recipe-side way to move
to a newer one.

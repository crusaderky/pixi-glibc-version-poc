#!/usr/bin/env bash
set -euo pipefail

SYSROOT="${CONDA_BUILD_SYSROOT:-$("${CC}" -print-sysroot)}"

echo "================================================================"
echo "what the recipe asked for vs. what it got"
echo "================================================================"
echo "variants.yaml control_key ....... ${CONTROL_KEY}"
echo "variants.yaml c_stdlib_version .. 2.34  (as written in the file)"
echo "resolved c_stdlib_version ....... ${C_STDLIB_VERSION}"
echo "resolved stdlib('c') ............ ${STDLIB_SPEC}"
echo "pixi.toml glibc system req ...... 2.34  (as written in the file)"
echo
echo "sysroot ......................... ${SYSROOT}"
echo -n "sysroot glibc ................... "
sed -n 's/^#define\s*__GLIBC_MINOR__\s*\([0-9]*\).*/2.\1/p' \
    "${SYSROOT}/usr/include/features.h"
echo -n "addchdir_np declared in sysroot . "
if grep -q posix_spawn_file_actions_addchdir_np "${SYSROOT}/usr/include/spawn.h"; then
    echo "yes"
else
    echo "NO  <-- the compile below cannot succeed"
fi
echo "================================================================"
echo

# The compiler never sees the host's /usr/include: conda's gcc is built with
# --with-sysroot, so <spawn.h> comes from the conda sysroot above, whatever
# glibc the machine running this build happens to have.
# -Werror=implicit-function-declaration so this is a hard failure on every gcc,
# not just the ones that promote it by default.
"${CC}" ${CFLAGS:-} -Werror=implicit-function-declaration \
    -o needs_glibc_229 needs_glibc_229.c

mkdir -p "${PREFIX}/bin"
cp needs_glibc_229 "${PREFIX}/bin/"

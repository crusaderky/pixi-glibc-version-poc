/* Compiles only against glibc >= 2.29.
 *
 * posix_spawn_file_actions_addchdir_np() was added in glibc 2.29 and is
 * declared in <spawn.h> under __USE_GNU. There is no way to reach it with an
 * older sysroot: the declaration is absent from the headers, and the symbol is
 * absent from the sysroot's libc, so neither a local prototype nor a link-time
 * workaround helps.
 *
 * This is the same call that broke a real build of llama.cpp, whose vendored
 * subprocess.h started using it to implement per-child working directories:
 * https://github.com/ggml-org/llama.cpp/commit/0cea36222fe9bac5ebfc45716c9eef11f37046c4
 */

#define _GNU_SOURCE
#include <spawn.h>
#include <stdio.h>

int main(void) {
    posix_spawn_file_actions_t actions;

    if (posix_spawn_file_actions_init(&actions) != 0) {
        return 1;
    }

    /* glibc >= 2.29 */
    if (posix_spawn_file_actions_addchdir_np(&actions, "/tmp") != 0) {
        return 1;
    }

    posix_spawn_file_actions_destroy(&actions);
    puts("built against a glibc that has posix_spawn_file_actions_addchdir_np");
    return 0;
}

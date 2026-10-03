// Test-only observation of the actual descriptor; no production lock internals.
#include <erl_nif.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static ERL_NIF_TERM close_on_exec(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary binary;
    char path[PATH_MAX];
    struct stat target, candidate;
    if (!enif_inspect_binary(env, argv[0], &binary) || binary.size >= sizeof(path))
        return enif_make_badarg(env);
    memcpy(path, binary.data, binary.size);
    path[binary.size] = 0;
    if (stat(path, &target) != 0) return enif_make_atom(env, "missing_file");
    long limit = sysconf(_SC_OPEN_MAX);
    for (int fd = 0; fd < limit; fd++) {
        if (fstat(fd, &candidate) == 0 && candidate.st_dev == target.st_dev &&
            candidate.st_ino == target.st_ino) {
            return enif_make_atom(env, (fcntl(fd, F_GETFD) & FD_CLOEXEC) ? "true" : "false");
        }
    }
    return enif_make_atom(env, "missing_descriptor");
}
static ErlNifFunc functions[] = {{"close_on_exec?", 1, close_on_exec, 0}};
ERL_NIF_INIT(Elixir.AtMcp.Test.NativeLockProbe, functions, NULL, NULL, NULL, NULL);

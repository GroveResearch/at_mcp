// SPDX-License-Identifier: Apache-2.0
// Derived from flock_ex 0.1.0 by nippynetworks (https://github.com/nippynetworks/flock_ex).
// See licenses/flock_ex/LICENSE and NOTICE.md for attribution and modifications.
// Locally owned because upstream lacks resource-lifetime ownership, close-on-exec,
// long paths and serialized cleanup. These prevent concurrent state writers after
// owner failure or child exec; test/at_mcp/native_lock_test.exs and state_lock_test.exs
// falsify the guarantees. Keep the lockfile inode: never unlink on release.

#define _GNU_SOURCE
#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

typedef struct {
    int fd;
    ErlNifPid owner;
    ErlNifMonitor monitor;
    ErlNifMutex* mutex;
} flock_handle_t;

static ErlNifResourceType* flock_handle_type = NULL;

// All explicit releases and owner-down callbacks serialize access to the fd.
// close() itself releases flock; do not retry close on an fd another thread may reuse.
static void release_lock(flock_handle_t* handle) {
    enif_mutex_lock(handle->mutex);
    if (handle->fd >= 0) {
        close(handle->fd);
        handle->fd = -1;
    }
    enif_mutex_unlock(handle->mutex);
}

static void flock_handle_dtor(ErlNifEnv* env, void* obj) {
    flock_handle_t* handle = (flock_handle_t*)obj;
    if (handle->mutex) {
        release_lock(handle);
        enif_mutex_destroy(handle->mutex);
    }
}

static void flock_handle_down(ErlNifEnv* env, void* obj, ErlNifPid* pid, ErlNifMonitor* mon) {
    release_lock((flock_handle_t*)obj);
}

static ErlNifResourceTypeInit flock_resource_callbacks = {
    .dtor = flock_handle_dtor,
    .down = flock_handle_down,
};

static int flock_resource_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    // New layout: never take over handles created by the original package.
    const char* name = "at_mcp_native_lock_v1";
    int flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    ErlNifResourceFlags tried;

    flock_handle_type = enif_open_resource_type_x(env, name, &flock_resource_callbacks, flags, &tried);
    return flock_handle_type ? 0 : 1;
}

static ERL_NIF_TERM make_error(ErlNifEnv* env, const char* reason) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, reason));
}

static ERL_NIF_TERM flock_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 2) return make_error(env, "badarity");

    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) ||
        memchr(bin.data, '\0', bin.size) != NULL) {
        return make_error(env, "badpath");
    }

    int exclusive = 1;
    int wait = 1;
    int monitor_owner = 1;

    if (!enif_is_list(env, argv[1])) {
        return make_error(env, "badopts");
    }

    ERL_NIF_TERM head, tail = argv[1];
    while (enif_get_list_cell(env, tail, &head, &tail)) {
        const ERL_NIF_TERM* tuple;
        int arity;
        if (enif_get_tuple(env, head, &arity, &tuple) && arity == 2) {
            if (enif_compare(tuple[0], enif_make_atom(env, "wait")) == 0) {
                if (tuple[1] == enif_make_atom(env, "false")) wait = 0;
            } else if (enif_compare(tuple[0], enif_make_atom(env, "exclusive")) == 0) {
                if (tuple[1] == enif_make_atom(env, "false")) exclusive = 0;
            } else if (enif_compare(tuple[0], enif_make_atom(env, "monitor_owner")) == 0) {
                if (tuple[1] == enif_make_atom(env, "false")) monitor_owner = 0;
            }
        }
    }

    if (bin.size == SIZE_MAX) return make_error(env, "path_too_long");
    char* path = enif_alloc(bin.size + 1);
    if (!path) return make_error(env, "enomem");
    memcpy(path, bin.data, bin.size);
    path[bin.size] = '\0';
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    enif_free(path);
    if (fd < 0) return make_error(env, "open_failed");

    int flags = exclusive ? LOCK_EX : LOCK_SH;
    if (!wait) flags |= LOCK_NB;
    if (flock(fd, flags) != 0) {
        int err = errno;
        close(fd);
        if (err == EWOULDBLOCK) return make_error(env, "eagain");
        return make_error(env, strerror(err));
    }

    flock_handle_t* handle = enif_alloc_resource(flock_handle_type, sizeof(flock_handle_t));
    if (!handle) {
        close(fd);
        return make_error(env, "enomem");
    }
    handle->fd = fd;
    handle->mutex = enif_mutex_create("flock_handle");
    if (!handle->mutex) {
        close(fd);
        handle->fd = -1;
        enif_release_resource(handle);
        return make_error(env, "enomem");
    }

    if (!enif_self(env, &handle->owner)) {
        enif_release_resource(handle);
        return make_error(env, "self_failed");
    }

    if (monitor_owner && enif_monitor_process(env, handle, &handle->owner, &handle->monitor) != 0) {
        enif_release_resource(handle);
        return make_error(env, "owner_unavailable");
    }

    ERL_NIF_TERM result = enif_make_resource(env, handle);
    enif_release_resource(handle);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), result);
}

static ERL_NIF_TERM unflock_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    flock_handle_t* handle;
    if (!enif_get_resource(env, argv[0], flock_handle_type, (void**)&handle)) {
        return make_error(env, "badhandle");
    }
    release_lock(handle);
    return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"do_flock", 2, flock_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"unflock", 1, unflock_nif, 0}};

ERL_NIF_INIT(Elixir.AtMcp.NativeLock, nif_funcs, flock_resource_load, NULL, NULL, NULL);

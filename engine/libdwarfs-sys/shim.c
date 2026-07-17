/* tebako_open() is a C variadic function (nargs, path, flags, ...) --
 * stable Rust cannot call true C variadics directly. This shim gives it a
 * fixed-arity signature for the one call shape we actually need:
 * read-only open, no mode argument. */
#include <fcntl.h>
#include <stddef.h>
#include <sys/types.h>
#include "tebako-io.h"

int abyssal_tebako_open_rdonly(const char *path) {
    return tebako_open(2, path, O_RDONLY);
}

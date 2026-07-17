// tebako-io.h uses size_t/off_t/ssize_t without including the headers that
// declare them -- it's normally compiled after other project headers have
// already pulled those in transitively. Bring them in explicitly since
// this is bindgen's only translation unit.
#include <stddef.h>
#include <sys/types.h>

// tebako-io.h feature-gates several declarations (tebako_pread, tebako_stat,
// ...) behind macros like `defined(TEBAKO_HAS_PREAD) && defined(_UNISTD_H)`
// -- i.e. both a build-config macro from tebako-config.h AND proof that
// <unistd.h>/<sys/stat.h> were already included. Without these, bindgen
// silently sees no declaration at all (not an error) and just omits the
// binding.
#include <unistd.h>
#include <sys/stat.h>
#include "tebako-config.h"

#include "tebako-io.h"

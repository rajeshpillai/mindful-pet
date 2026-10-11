/* Zig defines _FORTIFY_SOURCE in optimized builds; glibc's fortified
   wrappers use __attribute__((error)) which translate-c cannot handle.
   We don't need them for a translated header. */
#undef _FORTIFY_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/shape.h>
#include <X11/extensions/Xfixes.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <stdio.h>

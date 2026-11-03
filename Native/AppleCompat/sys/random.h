/* SPDX-License-Identifier: AGPL-3.0-or-later
 * MuPDF 1.28.6 includes macOS's <sys/random.h> on every Apple target.
 * iOS does not ship that header. Keep upstream sources untouched and provide
 * getentropy's small-buffer contract using Apple's cryptographically secure
 * arc4random_buf, available on all supported iPadOS versions.
 */
#ifndef PS_IOS_RANDOM_COMPAT_H
#define PS_IOS_RANDOM_COMPAT_H
#include <TargetConditionals.h>
#include <errno.h>
#include <stdlib.h>
#if !TARGET_OS_IPHONE
#error This compatibility header is for iOS device and simulator builds only.
#endif
static inline int ps_mupdf_getentropy(void *buffer, size_t length)
{
    if (length > 256) { errno = EIO; return -1; }
    arc4random_buf(buffer, length);
    return 0;
}
#define getentropy ps_mupdf_getentropy
#endif

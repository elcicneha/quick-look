/* config.h — hand-tuned for macOS builds of oniguruma 6.9.10
 *
 * This replaces the autoconf-generated config.h. All values reflect
 * a modern macOS (13+) toolchain (clang, 64-bit, Apple Silicon or x86_64).
 *
 * If you upgrade oniguruma, regenerate this by running its ./configure on
 * macOS and copying the resulting src/config.h over this file (or diffing).
 */

#ifndef ONIGURUMA_CONFIG_H
#define ONIGURUMA_CONFIG_H

/* Headers present on macOS */
#define HAVE_ALLOCA 1
#define HAVE_ALLOCA_H 1
#define HAVE_DLFCN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIMES_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1

#define STDC_HEADERS 1

/* Package metadata */
#define PACKAGE "onig"
#define PACKAGE_NAME "onig"
#define PACKAGE_TARNAME "onig"
#define PACKAGE_VERSION "6.9.10"
#define PACKAGE_STRING "onig 6.9.10"
#define PACKAGE_BUGREPORT ""
#define PACKAGE_URL ""
#define VERSION "6.9.10"

/* Sizeof values on 64-bit macOS (arm64 & x86_64 both match) */
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_VOIDP 8

/* Stack grows downward on arm64 and x86_64 */
#define STACK_DIRECTION (-1)

/* Line terminator: default LF only (don't treat CR+LF specially) */
/* #undef USE_CRNL_AS_LINE_TERMINATOR */

/* libtool uninstalled-lib sub-directory — unused in this build */
#define LT_OBJDIR ".libs/"

#endif /* ONIGURUMA_CONFIG_H */

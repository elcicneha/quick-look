/* OnigShim.h — tiny C shim exposing oniguruma macro-pointers as functions.
 *
 * `ONIG_ENCODING_UTF16_LE` and `ONIG_SYNTAX_ONIGURUMA` are C preprocessor
 * macros that expand to `&`-expressions on global structs. Swift's C importer
 * cannot take addresses of imported C globals, so we wrap the macros in
 * static inline functions. Imported into Swift as regular callable APIs.
 */

#ifndef ONIGSHIM_H
#define ONIGSHIM_H

#include "oniguruma.h"

static inline OnigEncodingType* onigshim_utf16le(void) {
    return ONIG_ENCODING_UTF16_LE;
}

static inline OnigEncodingType* onigshim_utf8(void) {
    return ONIG_ENCODING_UTF8;
}

static inline OnigSyntaxType* onigshim_syntax_oniguruma(void) {
    return ONIG_SYNTAX_ONIGURUMA;
}

#endif /* ONIGSHIM_H */

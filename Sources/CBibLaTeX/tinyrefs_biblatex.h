#ifndef TINYREFS_BIBLATEX_H
#define TINYREFS_BIBLATEX_H

#include <stddef.h>
#include <stdint.h>

enum {
    TINYREFS_BIBLATEX_OK = 0,
    TINYREFS_BIBLATEX_INVALID_INPUT = 1,
    TINYREFS_BIBLATEX_PARSE_ERROR = 2,
    TINYREFS_BIBLATEX_INTERNAL_ERROR = 3
};

typedef struct {
    const uint8_t * _Nonnull data;
    size_t len;
    int32_t status;
} TinyRefsBibLaTeXResult;

/*
 * Borrows len readable bytes for the duration of the call. A null input is
 * accepted for len == 0. The result contains UTF-8 JSON on success and a UTF-8
 * diagnostic otherwise. The bytes are read-only and have no NUL terminator.
 * Release every result exactly once using tinyrefs_biblatex_free.
 */
TinyRefsBibLaTeXResult tinyrefs_biblatex_parse(const uint8_t * _Nullable input, size_t len);

/* Consumes a result from tinyrefs_biblatex_parse and invalidates its buffer. */
void tinyrefs_biblatex_free(TinyRefsBibLaTeXResult result);

#endif

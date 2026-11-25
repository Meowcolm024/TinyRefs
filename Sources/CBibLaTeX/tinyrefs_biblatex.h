#ifndef TINYREFS_BIBLATEX_H
#define TINYREFS_BIBLATEX_H

#include <stddef.h>
#include <stdint.h>

enum {
    TINYREFS_BIBLATEX_OK = 0,
    TINYREFS_BIBLATEX_INVALID_INPUT = 1,
    TINYREFS_BIBLATEX_PARSE_ERROR = 2,
    TINYREFS_BIBLATEX_INTERNAL_ERROR = 3,
    TINYREFS_BIBLATEX_INVALID_METADATA = 4
};

typedef struct {
    const uint8_t * _Nonnull data;
    size_t len;
    int32_t status;
} TinyRefsBibLaTeXResult;

/*
 * Borrows len readable bytes for the duration of the call. A null input is
 * accepted for len == 0. The result contains UTF-8 reference JSON with a
 * structured object per reference on success and a UTF-8 diagnostic otherwise.
 * The bytes are read-only and have no NUL terminator.
 * Release every result exactly once using tinyrefs_biblatex_free.
 */
TinyRefsBibLaTeXResult tinyrefs_biblatex_parse(const uint8_t * _Nullable input, size_t len);

/*
 * Borrows len readable bytes of UTF-8 reference JSON for the duration of the
 * call. A null input is accepted for len == 0 and reports invalid JSON.
 * Returns UTF-8 JSON with a structured object per reference, or a UTF-8
 * diagnostic. The bytes are read-only and have no NUL terminator. Release
 * every result exactly once using tinyrefs_biblatex_free.
 */
TinyRefsBibLaTeXResult tinyrefs_biblatex_describe(const uint8_t * _Nullable input, size_t len);

/*
 * Borrows len readable bytes of UTF-8 list request JSON for the duration of the
 * call. The request supplies a field (author or keywords) and an expression.
 * Returns a JSON array of items or a diagnostic. A null input is accepted for
 * len == 0 and reports invalid JSON. The bytes are read-only and have no NUL
 * terminator. Release every result exactly once using tinyrefs_biblatex_free.
 */
TinyRefsBibLaTeXResult tinyrefs_biblatex_list_items(const uint8_t * _Nullable input, size_t len);

/*
 * Borrows len readable bytes of UTF-8 reference JSON for the duration of the
 * call. A null input is accepted for len == 0 and reports invalid JSON. The
 * result contains UTF-8 BibLaTeX on success and a UTF-8 diagnostic otherwise.
 * The bytes are read-only and have no NUL terminator. Release every result
 * exactly once using tinyrefs_biblatex_free.
 */
TinyRefsBibLaTeXResult tinyrefs_biblatex_serialize(const uint8_t * _Nullable input, size_t len);

/* Consumes a bridge result and invalidates its buffer. */
void tinyrefs_biblatex_free(TinyRefsBibLaTeXResult result);

#endif

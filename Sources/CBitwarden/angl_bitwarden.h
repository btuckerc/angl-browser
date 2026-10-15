// C ABI of bitwarden/ (Rust, over the official Bitwarden SDK). See bitwarden/src/lib.rs.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct AnglBwSession AnglBwSession;

typedef struct {
    uint8_t *ptr;
    size_t len;
    size_t cap;
} AnglBwBuf;

AnglBwSession *angl_bw_new(void);
void angl_bw_free(AnglBwSession *session);
/// JSON in; `{"ok": …}` or `{"error": {"kind", "message"}}` out. Free the result with angl_bw_buf_free.
AnglBwBuf angl_bw_call(AnglBwSession *session, const char *method, const uint8_t *input, size_t len);
void angl_bw_buf_free(AnglBwBuf buf);

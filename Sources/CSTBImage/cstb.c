#include "cstb.h"

#include <stdlib.h>
#include <string.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

unsigned char *cstb_decode_to_rgba(const unsigned char *data, int len,
                                   int *out_w, int *out_h) {
    int channels_in_file = 0;
    /* Force 4 channels so callers always get predictable RGBA8. */
    unsigned char *pixels =
        stbi_load_from_memory(data, len, out_w, out_h, &channels_in_file, 4);
    return pixels; /* NULL on failure. */
}

/* Growable buffer used to collect PNG output from stb's callback writer. */
typedef struct {
    unsigned char *bytes;
    int len;
    int cap;
    int failed;
} cstb_buffer;

static void cstb_buffer_append(void *context, void *data, int size) {
    cstb_buffer *buf = (cstb_buffer *)context;
    if (buf->failed) {
        return;
    }
    if (buf->len + size > buf->cap) {
        int new_cap = buf->cap > 0 ? buf->cap : 1024;
        while (new_cap < buf->len + size) {
            new_cap *= 2;
        }
        unsigned char *grown = (unsigned char *)realloc(buf->bytes, new_cap);
        if (grown == NULL) {
            buf->failed = 1;
            return;
        }
        buf->bytes = grown;
        buf->cap = new_cap;
    }
    memcpy(buf->bytes + buf->len, data, size);
    buf->len += size;
}

unsigned char *cstb_encode_rgba_to_png(const unsigned char *rgba, int w, int h,
                                       int *out_len) {
    cstb_buffer buf;
    buf.bytes = NULL;
    buf.len = 0;
    buf.cap = 0;
    buf.failed = 0;

    int stride = w * 4;
    int ok = stbi_write_png_to_func(cstb_buffer_append, &buf, w, h, 4, rgba,
                                    stride);
    if (!ok || buf.failed) {
        free(buf.bytes);
        return NULL;
    }
    *out_len = buf.len;
    return buf.bytes;
}

void cstb_free(void *ptr) {
    free(ptr);
}

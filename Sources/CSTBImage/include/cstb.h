#ifndef CSTB_H
#define CSTB_H

#include <stddef.h>

/*
 * Thin wrapper over stb_image / stb_image_write so Swift only sees a handful
 * of plain C functions. Used on Windows, where there is no system PNG codec
 * handed to us the way NSBitmapImageRep is on macOS.
 *
 * All returned buffers are heap-allocated and must be released with cstb_free.
 */

/* Decode encoded image bytes (PNG, BMP, etc.) into tightly-packed RGBA8.
 * Returns NULL on failure. On success, *out_w / *out_h receive the dimensions
 * and the buffer length is (*out_w * *out_h * 4). */
unsigned char *cstb_decode_to_rgba(const unsigned char *data, int len,
                                   int *out_w, int *out_h);

/* Encode tightly-packed RGBA8 pixels into a PNG in memory.
 * Returns NULL on failure. On success, *out_len receives the PNG byte count. */
unsigned char *cstb_encode_rgba_to_png(const unsigned char *rgba, int w, int h,
                                       int *out_len);

/* Free a buffer returned by the functions above. */
void cstb_free(void *ptr);

#endif /* CSTB_H */

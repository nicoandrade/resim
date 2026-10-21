#ifndef RESIM_CODECS_H
#define RESIM_CODECS_H
#include <stddef.h>
#include <stdint.h>
typedef int (*RCShouldCancel)(void *context);
typedef struct { int width, height, has_alpha, lossless; } RCImageInfo;
typedef struct { uint8_t *bytes; size_t size; } RCBuffer;
/* All errors/longjmp stay inside C. Caller owns returned buffers via rc_buffer_free. */
int rc_jpeg_inspect(const uint8_t *, size_t, RCImageInfo *, char *, size_t);
int rc_webp_inspect(const uint8_t *, size_t, RCImageInfo *, char *, size_t);
int rc_jpeg_optimize(const uint8_t *, size_t, int automatic, int strip_metadata,
                     RCShouldCancel, void *, RCBuffer *, char *, size_t);
int rc_webp_optimize(const uint8_t *, size_t, int automatic, int strip_metadata,
                     RCShouldCancel, void *, RCBuffer *, char *, size_t);
int rc_jpeg_coefficients_equal(const uint8_t *, size_t, const uint8_t *, size_t);
int rc_webp_pixels_equal(const uint8_t *, size_t, const uint8_t *, size_t);
/* Scores use B/G/R/A/All order, SSIM in dB. Return whether all RGB meet 30dB and alpha matches. */
int rc_jpeg_ssim_rgb(const uint8_t *, size_t, const uint8_t *, size_t, float scores[5]);
int rc_webp_ssim_rgb(const uint8_t *, size_t, const uint8_t *, size_t, float scores[5]);
int rc_avif_inspect(const uint8_t *, size_t, RCImageInfo *, char *, size_t);
int rc_avif_optimize(const uint8_t *, size_t, int automatic, int strip_metadata,
                     RCShouldCancel, void *, RCBuffer *, char *, size_t);
int rc_avif_pixels_equal(const uint8_t *, size_t, const uint8_t *, size_t);
int rc_avif_ssim_rgb(const uint8_t *, size_t, const uint8_t *, size_t);
/* Contiguous 8-bit RGBA, same 30dB RGB threshold and exact alpha as existing codecs. */
int rc_rgba_ssim_rgb(const uint8_t *, const uint8_t *, int width, int height);
int rc_zlib_equal(const uint8_t *, size_t, const uint8_t *, size_t);
int rc_exif_strip(const uint8_t *, size_t, RCBuffer *);
void rc_buffer_free(RCBuffer *);
#endif

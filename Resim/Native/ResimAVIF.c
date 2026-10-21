#include "ResimCodecs.h"
#include <avif/avif.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Keep AV1 in-process and bounded: one still image, 8-bit SDR and one codec thread.
 * The original file is never modified. Unknown properties are rejected because
 * moving an essential or ordered property into a new container can change meaning. */
static void avif_message(char *error, size_t capacity, const char *text) {
    if (error && capacity) snprintf(error, capacity, "%s", text);
}
static int avif_cancelled(RCShouldCancel callback, void *context) {
    return callback && callback(context);
}
static int supported_image(const avifDecoder *decoder, char *error, size_t capacity) {
    const avifImage *image = decoder->image;
    if (decoder->imageCount != 1 || decoder->imageSequenceTrackPresent ||
        decoder->progressiveState != AVIF_PROGRESSIVE_STATE_UNAVAILABLE) {
        avif_message(error, capacity, "Animated or progressive AVIF is not supported."); return 0;
    }
    if (!image->width || !image->height || (uint64_t)image->width * image->height > 40000000ULL) {
        avif_message(error, capacity, "The AVIF exceeds the 40-megapixel limit."); return 0;
    }
    if (image->depth != 8 || image->gainMap || image->clli.maxCLL || image->clli.maxPALL ||
        image->transferCharacteristics == AVIF_TRANSFER_CHARACTERISTICS_PQ ||
        image->transferCharacteristics == AVIF_TRANSFER_CHARACTERISTICS_HLG) {
        avif_message(error, capacity, "AVIF HDR, gain maps, or precision above 8 bits are not supported."); return 0;
    }
    if (image->numProperties ||
        (image->transformFlags & ~(AVIF_TRANSFORM_PASP | AVIF_TRANSFORM_CLAP | AVIF_TRANSFORM_IROT | AVIF_TRANSFORM_IMIR))) {
        avif_message(error, capacity, "The AVIF contains unsupported properties that must be preserved."); return 0;
    }
    return 1;
}
static avifDecoder *read_avif(const uint8_t *bytes, size_t size, int decode, char *error, size_t capacity) {
    avifDecoder *decoder = avifDecoderCreate();
    if (!decoder) { avif_message(error, capacity, "Not enough memory to open the AVIF."); return NULL; }
    decoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
    decoder->maxThreads = 1;
    decoder->imageSizeLimit = 40000000;
    decoder->imageDimensionLimit = 40000000;
    decoder->imageCountLimit = 1;
    decoder->imageContentToDecode = AVIF_IMAGE_CONTENT_ALL;
    avifResult result = avifDecoderSetIOMemory(decoder, bytes, size);
    if (result == AVIF_RESULT_OK) result = avifDecoderParse(decoder);
    if (result != AVIF_RESULT_OK) {
        avif_message(error, capacity, "AVIF is damaged, incomplete, or contains an unsupported sequence.");
        avifDecoderDestroy(decoder); return NULL;
    }
    if (!supported_image(decoder, error, capacity)) { avifDecoderDestroy(decoder); return NULL; }
    if (decode) {
        result = avifDecoderNextImage(decoder);
        if (result != AVIF_RESULT_OK) {
            avif_message(error, capacity, "Could not decode the AVIF safely.");
            avifDecoderDestroy(decoder); return NULL;
        }
        if (!supported_image(decoder, error, capacity)) { avifDecoderDestroy(decoder); return NULL; }
    }
    return decoder;
}
int rc_avif_inspect(const uint8_t *bytes, size_t size, RCImageInfo *info, char *error, size_t capacity) {
    avifDecoder *decoder = read_avif(bytes, size, 0, error, capacity);
    if (!decoder) return 0;
    info->width = (int)decoder->image->width;
    info->height = (int)decoder->image->height;
    info->has_alpha = decoder->alphaPresent;
    /* The container cannot certify that its AV1 bitstream was encoded losslessly. */
    info->lossless = 0;
    avifDecoderDestroy(decoder); return 1;
}
static int data_equal(const avifRWData *a, const avifRWData *b) {
    return a->size == b->size && (!a->size || !memcmp(a->data, b->data, a->size));
}
static int metadata_equal(const avifImage *a, const avifImage *b) {
    if (a->width != b->width || a->height != b->height || a->depth != b->depth ||
        a->yuvFormat != b->yuvFormat || a->yuvRange != b->yuvRange ||
        a->yuvChromaSamplePosition != b->yuvChromaSamplePosition ||
        a->alphaPremultiplied != b->alphaPremultiplied ||
        a->colorPrimaries != b->colorPrimaries || a->transferCharacteristics != b->transferCharacteristics ||
        a->matrixCoefficients != b->matrixCoefficients || a->transformFlags != b->transformFlags ||
        a->numProperties || b->numProperties || a->gainMap || b->gainMap ||
        !data_equal(&a->icc, &b->icc) || !data_equal(&a->exif, &b->exif) || !data_equal(&a->xmp, &b->xmp)) return 0;
    if ((a->transformFlags & AVIF_TRANSFORM_PASP) && memcmp(&a->pasp, &b->pasp, sizeof(a->pasp))) return 0;
    if ((a->transformFlags & AVIF_TRANSFORM_CLAP) && memcmp(&a->clap, &b->clap, sizeof(a->clap))) return 0;
    if ((a->transformFlags & AVIF_TRANSFORM_IROT) && a->irot.angle != b->irot.angle) return 0;
    if ((a->transformFlags & AVIF_TRANSFORM_IMIR) && a->imir.axis != b->imir.axis) return 0;
    return a->clli.maxCLL == b->clli.maxCLL && a->clli.maxPALL == b->clli.maxPALL;
}
static int plane_equal(const avifImage *a, const avifImage *b, int channel) {
    const uint8_t *ap = avifImagePlane(a, channel), *bp = avifImagePlane(b, channel);
    if (!ap || !bp) return ap == bp;
    uint32_t width = avifImagePlaneWidth(a, channel), height = avifImagePlaneHeight(a, channel);
    if (width != avifImagePlaneWidth(b, channel) || height != avifImagePlaneHeight(b, channel)) return 0;
    uint32_t astride = avifImagePlaneRowBytes(a, channel), bstride = avifImagePlaneRowBytes(b, channel);
    for (uint32_t y = 0; y < height; ++y) if (memcmp(ap + (size_t)y * astride, bp + (size_t)y * bstride, width)) return 0;
    return 1;
}
static int pixels_equal(const avifImage *a, const avifImage *b) {
    if (!metadata_equal(a, b)) return 0;
    for (int channel = AVIF_CHAN_Y; channel <= AVIF_CHAN_A; ++channel) if (!plane_equal(a, b, channel)) return 0;
    return 1;
}
static int quality_equal(const avifImage *a, const avifImage *b, int profile) {
    if (!metadata_equal(a, b) || !plane_equal(a, b, AVIF_CHAN_A) || a->alphaPremultiplied) return 0;
    avifRGBImage x, y;
    avifRGBImageSetDefaults(&x, a); avifRGBImageSetDefaults(&y, b);
    x.format = y.format = AVIF_RGB_FORMAT_RGBA;
    x.depth = y.depth = 8;
    x.avoidLibYUV = y.avoidLibYUV = AVIF_TRUE;
    int valid = avifRGBImageAllocatePixels(&x) == AVIF_RESULT_OK;
    if (valid) valid = avifRGBImageAllocatePixels(&y) == AVIF_RESULT_OK;
    if (valid) valid = avifImageYUVToRGB(a, &x) == AVIF_RESULT_OK && avifImageYUVToRGB(b, &y) == AVIF_RESULT_OK;
    /* Preserve RGB hidden below fully transparent samples as well as alpha itself. */
    if (valid) for (uint32_t row = 0; row < a->height && valid; ++row) {
        const uint8_t *xp = x.pixels + (size_t)row * x.rowBytes, *yp = y.pixels + (size_t)row * y.rowBytes;
        for (uint32_t col = 0; col < a->width; ++col) if (xp[col * 4 + 3] == 0 && memcmp(xp + col * 4, yp + col * 4, 4)) { valid = 0; break; }
    }
    if (valid) valid = x.rowBytes == a->width * 4 && y.rowBytes == b->width * 4 &&
        rc_rgba_quality_rgb(x.pixels, y.pixels, (int)a->width, (int)a->height, profile);
    avifRGBImageFreePixels(&x); avifRGBImageFreePixels(&y);
    return valid;
}
int rc_avif_pixels_equal(const uint8_t *a, size_t an, const uint8_t *b, size_t bn) {
    avifDecoder *x = read_avif(a, an, 1, NULL, 0), *y = read_avif(b, bn, 1, NULL, 0);
    int result = x && y && pixels_equal(x->image, y->image);
    if (x) avifDecoderDestroy(x); if (y) avifDecoderDestroy(y); return result;
}
int rc_avif_ssim_rgb(const uint8_t *a, size_t an, const uint8_t *b, size_t bn) {
    avifDecoder *x = read_avif(a, an, 1, NULL, 0), *y = read_avif(b, bn, 1, NULL, 0);
    int result = x && y && quality_equal(x->image, y->image, 1);
    if (x) avifDecoderDestroy(x); if (y) avifDecoderDestroy(y); return result;
}
int rc_avif_quality_rgb(const uint8_t *a, size_t an, const uint8_t *b, size_t bn, int profile) {
    avifDecoder *x = read_avif(a, an, 1, NULL, 0), *y = read_avif(b, bn, 1, NULL, 0);
    int result = rc_profile_attempts(profile) && x && y && quality_equal(x->image, y->image, profile);
    if (x) avifDecoderDestroy(x); if (y) avifDecoderDestroy(y); return result;
}
static int encode_candidate(const avifImage *image, int quality, avifRWData *output, char *error, size_t capacity) {
    avifEncoder *encoder = avifEncoderCreate();
    if (!encoder) { avif_message(error, capacity, "Not enough memory to optimize the AVIF."); return 0; }
    encoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
    encoder->maxThreads = 1;
    encoder->speed = 6;
    encoder->quality = quality;
    encoder->qualityAlpha = AVIF_QUALITY_LOSSLESS;
    avifResult result = avifEncoderWrite(encoder, image, output);
    if (result != AVIF_RESULT_OK) avif_message(error, capacity, "Could not encode the AVIF safely.");
    avifEncoderDestroy(encoder); return result == AVIF_RESULT_OK;
}
int rc_avif_optimize(const uint8_t *bytes, size_t size, int profile, int strip,
                     RCShouldCancel callback, void *context, RCBuffer *output, char *error, size_t capacity) {
    output->bytes = NULL; output->size = 0;
    if (avif_cancelled(callback, context)) { avif_message(error, capacity, "Cancelled."); return 0; }
    avifDecoder *decoder = read_avif(bytes, size, 1, error, capacity);
    if (!decoder) return 0;
    avifImage *image = avifImageCreateEmpty();
    avifRWData best = AVIF_DATA_EMPTY;
    int success = image && avifImageCopy(image, decoder->image, AVIF_PLANES_ALL) == AVIF_RESULT_OK;
    /* The deep copy owns all planes and metadata. Release AOM's original frame
     * buffers before encoding or allocating the candidate and SSIM buffers. */
    avifDecoderDestroy(decoder);
    decoder = NULL;
    if (!success) avif_message(error, capacity, "Not enough memory to optimize the AVIF.");
    if (success && strip && image->exif.size) {
        RCBuffer clean = {0};
        if (rc_exif_strip(image->exif.data, image->exif.size, &clean)) {
            /* SetMetadataExif derives orientation; retain the actual container transforms exactly. */
            avifTransformFlags flags = image->transformFlags;
            avifImageRotation rotation = image->irot; avifImageMirror mirror = image->imir;
            success = avifImageSetMetadataExif(image, clean.bytes, clean.size) == AVIF_RESULT_OK;
            if (!success) avif_message(error, capacity, "Not enough memory to preserve AVIF metadata.");
            image->transformFlags = flags; image->irot = rotation; image->imir = mirror;
            rc_buffer_free(&clean);
        }
        /* Preserve XMP: unknown namespaces may carry presentation or color semantics. */
    }
    for (int pass = 0; success && pass < 1 + rc_profile_attempts(profile); ++pass) {
        if (avif_cancelled(callback, context)) { success = 0; break; }
        avifRWData encoded = AVIF_DATA_EMPTY;
        if (pass && image->alphaPremultiplied) break;
        int encoded_ok = encode_candidate(image, pass ? (int)rc_profile_quality(profile, 2, pass - 1) : AVIF_QUALITY_LOSSLESS, &encoded, error, capacity);
        /* Automatic recompression is optional: keep the validated strict result if it fails. */
        if (!encoded_ok && pass) { avifRWDataFree(&encoded); break; }
        success = encoded_ok;
        if (success && encoded.size < (best.size ? best.size : size) && !avif_cancelled(callback, context)) {
            avifDecoder *candidate = read_avif(encoded.data, encoded.size, 1, NULL, 0);
            int accepted = candidate && (pass ? quality_equal(image, candidate->image, profile) : pixels_equal(image, candidate->image));
            if (accepted) { avifRWDataFree(&best); best = encoded; encoded = (avifRWData)AVIF_DATA_EMPTY; }
            if (candidate) avifDecoderDestroy(candidate);
        }
        avifRWDataFree(&encoded);
    }
    if (avif_cancelled(callback, context)) { avif_message(error, capacity, "Cancelled."); success = 0; }
    if (success && best.size) {
        output->bytes = malloc(best.size);
        if (output->bytes) { memcpy(output->bytes, best.data, best.size); output->size = best.size; }
        else { avif_message(error, capacity, "Not enough memory to save the AVIF."); success = 0; }
    }
    avifRWDataFree(&best);
    if (image) avifImageDestroy(image);
    if (decoder) avifDecoderDestroy(decoder);
    return success;
}

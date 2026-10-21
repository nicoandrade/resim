/* Original deterministic Release-QA encoder. Not distributed with the app.
 * Accepts raw, contiguous 8-bit RGBA produced by ReleaseQATests. */
#include <avif/avif.h>
#include <webp/encode.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); exit(1); }
}
static void save(const char *prefix, const char *extension, const unsigned char *bytes, size_t size) {
    char path[4096]; require(snprintf(path, sizeof(path), "%s.%s", prefix, extension) < (int)sizeof(path), "Path too long");
    FILE *file = fopen(path, "wb"); require(file != NULL, "Cannot open encoded fixture");
    require(fwrite(bytes, 1, size, file) == size, "Cannot write encoded fixture"); fclose(file);
}
static void avif_check(avifResult result) { require(result == AVIF_RESULT_OK, avifResultToString(result)); }
int main(int argc, char **argv) {
    if (argc != 6) return 2;
    int width = atoi(argv[2]), height = atoi(argv[3]), variant = atoi(argv[5]);
    require(width > 0 && height > 0 && (size_t)width * height <= 6000000, "Invalid size");
    size_t size = (size_t)width * height * 4;
    unsigned char *pixels = malloc(size); require(pixels != NULL, "Allocation failed");
    FILE *file = fopen(argv[1], "rb"); require(file != NULL, "Cannot open pixels");
    require(fread(pixels, 1, size, file) == size && fgetc(file) == EOF, "Invalid RGBA length"); fclose(file);
    WebPConfig config; WebPPicture picture; WebPMemoryWriter writer;
    require(WebPConfigInit(&config) && WebPPictureInit(&picture), "WebP ABI mismatch");
    config.lossless = variant % 2 == 0; config.exact = 1; config.method = 0;
    config.quality = config.lossless ? 0 : 100; config.thread_level = 0;
    picture.width = width; picture.height = height; picture.use_argb = 1;
    WebPMemoryWriterInit(&writer); picture.writer = WebPMemoryWrite; picture.custom_ptr = &writer;
    require(WebPPictureImportRGBA(&picture, pixels, width * 4) && WebPEncode(&config, &picture), "WebP encode failed");
    save(argv[4], "webp", writer.mem, writer.size);
    WebPPictureFree(&picture); WebPMemoryWriterClear(&writer);
    avifImage *image = avifImageCreate(width, height, 8, AVIF_PIXEL_FORMAT_YUV444);
    require(image != NULL, "AVIF allocation failed");
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709;
    image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_IDENTITY;
    image->yuvRange = AVIF_RANGE_FULL;
    avifRGBImage rgb; avifRGBImageSetDefaults(&rgb, image);
    rgb.format = AVIF_RGB_FORMAT_RGBA; rgb.pixels = pixels; rgb.rowBytes = width * 4;
    avif_check(avifImageRGBToYUV(image, &rgb));
    avifEncoder *encoder = avifEncoderCreate(); require(encoder != NULL, "AVIF encoder allocation failed");
    encoder->codecChoice = AVIF_CODEC_CHOICE_AOM; encoder->maxThreads = 1; encoder->speed = 10;
    encoder->quality = variant % 2 == 0 ? 100 : 90; encoder->qualityAlpha = 100;
    avifRWData encoded = AVIF_DATA_EMPTY; avif_check(avifEncoderWrite(encoder, image, &encoded));
    save(argv[4], "avif", encoded.data, encoded.size);
    avifRWDataFree(&encoded); avifEncoderDestroy(encoder); avifImageDestroy(image); free(pixels);
    return 0;
}

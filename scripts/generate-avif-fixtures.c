/* Reproducible AVIF samples. Build after build-codecs.sh:
 * clang -Ivendor/build/include scripts/generate-avif-fixtures.c
 *   -Lvendor/build/lib -lavif -laom -lc++ -lm -lpthread -o .build/avif-fixtures
 * .build/avif-fixtures ResimTests/Fixtures
 */
#include <avif/avif.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(avifResult result) {
    if (result != AVIF_RESULT_OK) { fprintf(stderr, "%s\n", avifResultToString(result)); exit(1); }
}
static avifImage *image(unsigned width, unsigned height, unsigned depth, int alpha) {
    avifImage *result = avifImageCreate(width, height, depth, AVIF_PIXEL_FORMAT_YUV444);
    if (!result) exit(1);
    result->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709;
    result->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    result->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_IDENTITY;
    result->yuvRange = AVIF_RANGE_FULL;
    check(avifImageAllocatePlanes(result, alpha ? AVIF_PLANES_ALL : AVIF_PLANES_YUV));
    for (int plane = 0; plane < 3; ++plane) for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) {
        unsigned value = 24 + (x * 143 / width + y * 53 / height + plane * 17) % 200;
        if (depth == 8) result->yuvPlanes[plane][(size_t)y * result->yuvRowBytes[plane] + x] = value;
        else ((uint16_t *)(result->yuvPlanes[plane] + (size_t)y * result->yuvRowBytes[plane]))[x] = value * 4;
        if (alpha) result->alphaPlane[(size_t)y * result->alphaRowBytes + x] = x < width / 3 ? 0 : x < width * 2 / 3 ? 127 : 255;
    }
    return result;
}
static void write_image(const char *root, const char *name, avifImage *image, int quality, int sequence, int padding) {
    avifEncoder *encoder = avifEncoderCreate(); if (!encoder) exit(1);
    encoder->codecChoice = AVIF_CODEC_CHOICE_AOM; encoder->maxThreads = 1;
    encoder->speed = 10; encoder->quality = quality; encoder->qualityAlpha = 100;
    avifRWData data = AVIF_DATA_EMPTY;
    if (sequence) {
        check(avifEncoderAddImage(encoder, image, 1, AVIF_ADD_IMAGE_FLAG_NONE));
        check(avifEncoderAddImage(encoder, image, 1, AVIF_ADD_IMAGE_FLAG_NONE));
        check(avifEncoderFinish(encoder, &data));
    } else check(avifEncoderWrite(encoder, image, &data));
    char path[4096]; snprintf(path, sizeof(path), "%s/%s", root, name);
    FILE *file = fopen(path, "wb"); if (!file) exit(1);
    if (fwrite(data.data, 1, data.size, file) != data.size) exit(1);
    if (padding) {
        /* A valid, useless BMFF free box: guarantees the strict candidate can shrink. */
        static const uint8_t free_box[16384] = {0, 0, 64, 0, 'f', 'r', 'e', 'e'};
        if (fwrite(free_box, 1, sizeof(free_box), file) != sizeof(free_box)) exit(1);
    }
    fclose(file); printf("%s: %zu bytes\n", name, data.size + (padding ? 16384 : 0));
    avifRWDataFree(&data); avifEncoderDestroy(encoder);
}
static void metadata(avifImage *image, const char *root) {
    /* Little-endian TIFF, orientation 6 and a long artist value stripped in privacy mode. */
    static const uint8_t exif[] = {
        'I','I',42,0,8,0,0,0,2,0,
        0x12,1,3,0,1,0,0,0,6,0,0,0,
        0x3b,1,2,0,24,0,0,0,38,0,0,0,
        0,0,0,0,
        'R','e','s','i','m',' ','P','r','i','v','a','t','e',' ','A','r','t','i','s','t',' ','X','X',0
    };
    static const char xmp[] = "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description xmlns:custom='https://resim.example/essential/' custom:Orientation='6'/></rdf:RDF></x:xmpmeta>";
    check(avifImageSetMetadataExif(image, exif, sizeof(exif)));
    check(avifImageSetMetadataXMP(image, (const uint8_t *)xmp, strlen(xmp)));
    image->transformFlags |= AVIF_TRANSFORM_PASP | AVIF_TRANSFORM_CLAP | AVIF_TRANSFORM_IMIR;
    image->pasp = (avifPixelAspectRatioBox){1, 1};
    image->clap = (avifCleanApertureBox){112,1,80,1,0,1,0,1};
    image->imir.axis = 1;
    char path[4096]; snprintf(path, sizeof(path), "%s/sRGB.icc", root);
    FILE *file = fopen(path, "rb");
    if (!file) exit(1);
    fseek(file, 0, SEEK_END); long size = ftell(file); rewind(file);
    if (size <= 0 || size > 1024 * 1024) exit(1);
    uint8_t *icc = malloc((size_t)size); if (!icc) exit(1);
    if (fread(icc, 1, (size_t)size, file) != (size_t)size) exit(1);
    fclose(file); check(avifImageSetProfileICC(image, icc, (size_t)size)); free(icc);
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    avifImage *source = image(128,96,8,1);
    write_image(argv[1], "avif-lossless-alpha.avif", source,100,0,1);
    metadata(source, argv[1]);
    write_image(argv[1], "avif-orientation-icc.avif", source,100,0,1);
    avifImageDestroy(source);
    source = image(768,384,8,0);
    write_image(argv[1], "avif-auto.avif", source,100,0,0);
    avifImageDestroy(source);
    source = image(128,96,8,0);
    write_image(argv[1], "avif-lossy.avif", source,50,0,1);
    write_image(argv[1], "avif-degraded.avif", source,5,0,0);
    write_image(argv[1], "avif-animated.avif", source,80,1,0);
    static const uint8_t payload[] = {1,2,3,4};
    check(avifImageAddOpaqueProperty(source, (const uint8_t *)"rSIM", payload, sizeof(payload)));
    write_image(argv[1], "avif-unknown-property.avif", source,80,0,0);
    avifImageDestroy(source);
    source = image(128,96,10,0);
    source->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_PQ;
    write_image(argv[1], "avif-hdr10.avif", source,80,0,0);
    avifImageDestroy(source);
    source = image(128,96,8,0);
    source->gainMap = avifGainMapCreate(); if (!source->gainMap) exit(1);
    source->gainMap->image = image(32,24,8,0);
    source->gainMap->image->colorPrimaries = AVIF_COLOR_PRIMARIES_UNSPECIFIED;
    source->gainMap->image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_UNSPECIFIED;
    source->gainMap->alternateHdrHeadroom.n = 2;
    write_image(argv[1], "avif-gain-map.avif", source,80,0,0);
    avifImageDestroy(source);
    return 0;
}

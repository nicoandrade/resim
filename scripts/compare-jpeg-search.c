/* Offline calibration only: reuse the production encoder and admission policy. */
#include "../Resim/Native/ResimCodecs.c"
int qa_jpeg_auto_safe(const uint8_t *bytes, size_t size) {
    return jpeg_auto_safe(bytes, size);
}
int qa_jpeg_encode(const uint8_t *bytes, size_t size, int quality, RCBuffer *output) {
    return jpeg_encode(bytes, size, quality, 0, NULL, NULL, output);
}

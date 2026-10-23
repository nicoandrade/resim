/* Use the same libwebp SSIM implementation as the shipping quality gate. */
#include <webp/encode.h>
#include <stdint.h>
int qa_rgba_metrics(const uint8_t *a, const uint8_t *b, int w, int h, float scores[5]) {
    WebPPicture p, q;
    if (!WebPPictureInit(&p) || !WebPPictureInit(&q)) return 0;
    p.use_argb = q.use_argb = 1;
    p.width = q.width = w; p.height = q.height = h;
    int ok = WebPPictureImportRGBA(&p, a, w * 4) && WebPPictureImportRGBA(&q, b, w * 4);
    if (ok) ok = WebPPictureDistortion(&p, &q, 1, scores);
    WebPPictureFree(&p); WebPPictureFree(&q);
    return ok;
}

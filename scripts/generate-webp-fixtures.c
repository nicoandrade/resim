/* Procedural test data authored for Resim; generated binaries may be redistributed. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <webp/encode.h>
#include <webp/mux.h>
static void save(const char *name, const uint8_t *p, size_t n) {
  char path[1024]; snprintf(path, sizeof(path), "ResimTests/Fixtures/%s", name);
  FILE *f = fopen(path, "wb"); if (!f || fwrite(p, 1, n, f) != n) exit(2); fclose(f);
}
int main(void) {
  enum { w = 192, h = 128 };
  uint8_t pixels[w*h*4];
  for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
    uint8_t *p = pixels+(y*w+x)*4;
    p[0]=x; p[1]=y*2; p[2]=(x^y); p[3]=x<24?0:x<48?96:255;
  }
  WebPConfig config; WebPPicture pic; WebPMemoryWriter writer;
  WebPConfigInit(&config); config.lossless=1; config.exact=1; config.method=0; config.quality=0;
  WebPPictureInit(&pic); pic.width=w; pic.height=h; pic.use_argb=1;
  WebPMemoryWriterInit(&writer); pic.writer=WebPMemoryWrite; pic.custom_ptr=&writer;
  if(!WebPPictureImportRGBA(&pic,pixels,w*4)||!WebPEncode(&config,&pic))return 1;
  save("exact-alpha.webp",writer.mem,writer.size);
  WebPData data={writer.mem,writer.size};
  WebPMux *mux=WebPMuxNew();
  WebPMuxAnimParams anim={0,0};
  WebPMuxSetAnimationParams(mux,&anim);
  WebPMuxFrameInfo frame; memset(&frame,0,sizeof(frame));
  frame.bitstream=data; frame.duration=100; frame.id=WEBP_CHUNK_ANMF;
  WebPMuxPushFrame(mux,&frame,1); frame.duration=200; WebPMuxPushFrame(mux,&frame,1);
  WebPData animated={0};
  if(WebPMuxAssemble(mux,&animated)!=WEBP_MUX_OK)return 3;
  save("animated.webp",animated.bytes,animated.size);
  WebPDataClear(&animated); WebPMuxDelete(mux);
  WebPPictureFree(&pic); WebPMemoryWriterClear(&writer);
  for(int y=0;y<h;y++)for(int x=0;x<w;x++){uint8_t*p=pixels+(y*w+x)*4;p[3]=255;}
  uint8_t *lossy=NULL; size_t n=WebPEncodeRGBA(pixels,w,h,w*4,100,&lossy);
  if(!n)return 4; save("lossy.webp",lossy,n); WebPFree(lossy);
  return 0;
}

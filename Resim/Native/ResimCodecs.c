#include "ResimCodecs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <math.h>
#include <zlib.h>
#include <jpeglib.h>
#include <webp/decode.h>
#include <webp/encode.h>
#include <webp/demux.h>
#include <webp/mux.h>

#define MAX_PIXELS 40000000ULL
#define SSIM_MIN_DB 30.0f
int rc_profile_attempts(int profile) {
 return profile == 1 ? 1 : profile == 2 ? 7 : profile == 3 ? 10 : 0;
}
float rc_profile_min_ssim_db(int profile) {
 return profile == 3 ? 16.f : profile == 2 ? 20.f : SSIM_MIN_DB;
}
double rc_profile_quality(int profile, int format, int attempt) {
 static const double qualities[4][10] = {
  {98, 95, 92, 88, 84, 80, 76, 70, 64, 58},
  {98, 94, 90, 85, 80, 75, 70, 60, 50, 40},
  {95, 90, 85, 80, 75, 65, 55, 45, 35, 25},
  {.95, .90, .85, .80, .75, .70, .65, .55, .45, .35}
 };
 if(format < 0 || format > 3 || attempt < 0 || attempt >= rc_profile_attempts(profile)) return -1;
 static const double conservative[4] = {92, 90, 95, .85};
 return profile == 1 ? conservative[format] : qualities[format][attempt];
}
static void message(char *e, size_t n, const char *s) { if(e && n) snprintf(e,n,"%s",s); }
void rc_buffer_free(RCBuffer *b) { free(b->bytes); b->bytes=NULL; b->size=0; }
static int cancelled(RCShouldCancel cb,void *ctx){ return cb && cb(ctx); }
static int dimensions(unsigned w,unsigned h){ return w && h && (uint64_t)w*h<=MAX_PIXELS; }

typedef struct { struct jpeg_error_mgr base; jmp_buf jump; char text[JMSG_LENGTH_MAX]; int warnings; } JError;
static void jpeg_fail(j_common_ptr p){ JError *e=(JError*)p->err; (*p->err->format_message)(p,e->text); longjmp(e->jump,1); }
static void jpeg_message(j_common_ptr p,int level){ if(level<0)((JError*)p->err)->warnings++; }
typedef struct {
 struct jpeg_decompress_struct d; struct jpeg_compress_struct c;
 JError e; int dc,cc; unsigned char *encoded,*pixels; unsigned long encoded_size;
} JPEGState;
static JPEGState *jpeg_state(void){ JPEGState *s=calloc(1,sizeof(*s)); if(s){ s->d.err=jpeg_std_error(&s->e.base); s->e.base.error_exit=jpeg_fail; s->e.base.emit_message=jpeg_message; s->c.err=&s->e.base; } return s; }
static void jpeg_cleanup(JPEGState *s){ if(!s)return; if(s->cc)jpeg_destroy_compress(&s->c); if(s->dc)jpeg_destroy_decompress(&s->d); free(s->encoded);free(s->pixels);free(s); }
static int jpeg_header(JPEGState*s,const uint8_t*b,size_t n){
 jpeg_create_decompress(&s->d);s->dc=1;
 for(int i=0;i<16;i++)jpeg_save_markers(&s->d,JPEG_APP0+i,0xffff);
 jpeg_save_markers(&s->d,JPEG_COM,0xffff);jpeg_mem_src(&s->d,b,n);
 if(jpeg_read_header(&s->d,TRUE)!=JPEG_HEADER_OK)return 0;
 if(s->d.data_precision!=8 || (s->d.jpeg_color_space!=JCS_RGB && s->d.jpeg_color_space!=JCS_YCbCr && s->d.jpeg_color_space!=JCS_GRAYSCALE))return 0;
 if(!dimensions(s->d.image_width,s->d.image_height))return 0;
 for(jpeg_saved_marker_ptr m=s->d.marker_list;m;m=m->next){
  if(m->marker==JPEG_APP0+2 && m->data_length>=4 && !memcmp(m->data,"MPF\0",4))return 0;
  // Multi-picture/HDR/gain maps cannot be safely reduced to a conventional JPEG.
  if(m->data_length && (memmem(m->data,m->data_length,"hdrgm:",6)||memmem(m->data,m->data_length,"hdr-gain-map",12)||memmem(m->data,m->data_length,"HDRGainMap",10)))return 0;
 }
 return !s->e.warnings;
}
int rc_jpeg_inspect(const uint8_t*b,size_t n,RCImageInfo*i,char*e,size_t en){
 JPEGState*s=jpeg_state();if(!s)return 0;
 if(setjmp(s->e.jump)){message(e,en,"Damaged or incomplete JPEG.");jpeg_cleanup(s);return 0;}
 int ok=jpeg_header(s,b,n);if(ok){i->width=s->d.image_width;i->height=s->d.image_height;i->has_alpha=0;i->lossless=0;}
 else message(e,en,"Unsupported JPEG (CMYK, HDR, precision, or header).");jpeg_cleanup(s);return ok;
}
static unsigned read16(const uint8_t*p,int le){return le?(p[0]|p[1]<<8):(p[0]<<8|p[1]);}
static uint32_t read32(const uint8_t*p,int le){return le?((uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24):((uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]);}
typedef struct { unsigned tag,type,count; size_t size; const uint8_t*value; int child; } ExifField;
typedef struct { ExifField fields[24]; unsigned count; } ExifIFD;
static void put16end(uint8_t*p,unsigned v,int le){if(le){p[0]=v;p[1]=v>>8;}else{p[0]=v>>8;p[1]=v;}}
static void put32end(uint8_t*p,uint32_t v,int le){if(le){for(int i=0;i<4;i++)p[i]=v>>(i*8);}else{for(int i=0;i<4;i++)p[i]=v>>(24-i*8);}}
static int exif_read_ifd(const uint8_t*t,size_t n,uint32_t off,int le,int which,ExifIFD ifds[3]){
 if(off>n-2)return 0;unsigned count=read16(t+off,le);if(count>(n-off-2)/12)return 0;
 for(unsigned k=0;k<count;k++){
  const uint8_t*p=t+off+2+12*k;unsigned tag=read16(p,le),type=read16(p+2,le);uint32_t cnt=read32(p+4,le);
  int child=-1;
  if(which==0&&tag==34665)child=1;else if(which==1&&tag==40965)child=2;
  int keep=which==0?(tag==274||tag==34675||tag==301||tag==318||tag==319||tag==529||tag==531||tag==532):which==1?(tag==40961||tag==42240):(tag==1||tag==2);
  if(child>=0){if(type!=4||cnt!=1||!exif_read_ifd(t,n,read32(p+8,le),le,child,ifds))return 0;keep=ifds[child].count>0;}
  if(!keep)continue;
  static const unsigned sizes[]={0,1,1,2,4,8,1,1,2,4,8,4,8};if(type>12||!sizes[type]||cnt>65535/sizes[type])return 0;
  size_t sz=(size_t)cnt*sizes[type];uint32_t valueoff=sz>4?read32(p+8,le):0;
  if(sz>4&&(valueoff>n||sz>n-valueoff))return 0;
  ExifIFD*f=&ifds[which];if(f->count>=24)return 0;
  f->fields[f->count++]=(ExifField){tag,type,cnt,sz,sz>4?t+valueoff:p+8,child};
 }return 1;
}
int rc_exif_strip(const uint8_t*source,size_t size,RCBuffer*out){
 out->bytes=NULL;out->size=0;int prefix=size>=6&&!memcmp(source,"Exif\0\0",6);const uint8_t*t=source+(prefix?6:0);size_t n=size-(prefix?6:0);
 if(n<8)return 0;int le=t[0]=='I'&&t[1]=='I';if(!le&&!(t[0]=='M'&&t[1]=='M'))return 0;if(read16(t+2,le)!=42)return 0;
 ExifIFD ifds[3]={0};if(!exif_read_ifd(t,n,read32(t+4,le),le,0,ifds))return 0;
 size_t offsets[3]={8,0,0};size_t total=8;
 for(int j=0;j<3;j++)if(j==0||ifds[j].count){offsets[j]=total;total+=2+12*ifds[j].count+4;}
 size_t extra=total;
 for(int j=0;j<3;j++)for(unsigned k=0;k<ifds[j].count;k++)if(ifds[j].fields[k].size>4)total+=ifds[j].fields[k].size+(ifds[j].fields[k].size&1);
 if(total>n)return 0;
 uint8_t*buf=calloc(1,total+(prefix?6:0));if(!buf)return 0;if(prefix)memcpy(buf,"Exif\0\0",6);uint8_t*d=buf+(prefix?6:0);d[0]=d[1]=le?'I':'M';put16end(d+2,42,le);put32end(d+4,8,le);
 for(int j=0;j<3;j++)if(j==0||ifds[j].count){put16end(d+offsets[j],ifds[j].count,le);for(unsigned k=0;k<ifds[j].count;k++){
  ExifField*f=&ifds[j].fields[k];uint8_t*p=d+offsets[j]+2+12*k;put16end(p,f->tag,le);put16end(p+2,f->type,le);put32end(p+4,f->count,le);
  if(f->child>=0)put32end(p+8,(uint32_t)offsets[f->child],le);
  else if(f->size<=4)memcpy(p+8,f->value,f->size);
  else{put32end(p+8,(uint32_t)extra,le);memcpy(d+extra,f->value,f->size);extra+=f->size+(f->size&1);}
 }}
 out->bytes=buf;out->size=total+(prefix?6:0);return 1;
}
/* XMP may carry orientation, color interpretation or unknown extension semantics.
 * Keep those packets whole. Known conventional personal-only packets are removable. */
static int xmp_can_strip(const uint8_t*p,size_t n){
 static const char*essential[]={"Orientation","ColorSpace","Gamma","ICC","WhitePoint","PrimaryChromaticities","TransferFunction","YCbCr","RenderingIntent","Profile","hdr","GainMap","crs:","CameraRaw",NULL};
 for(int k=0;essential[k];k++)if(memmem(p,n,essential[k],strlen(essential[k])))return 0;
 // Restrict removal to packets with recognizable XMP/RDF structure.
 if(!memmem(p,n,"rdf:RDF",7))return 0;
 static const char*uris[]={"adobe:ns:meta/","http://www.w3.org/1999/02/22-rdf-syntax-ns#","http://ns.adobe.com/xap/1.0/","http://purl.org/dc/elements/1.1/","http://ns.adobe.com/photoshop/1.0/","http://ns.adobe.com/tiff/1.0/","http://ns.adobe.com/exif/1.0/","http://ns.adobe.com/exif/1.0/aux/","http://ns.adobe.com/xap/1.0/rights/",NULL};
 if(memmem(p,n,"<!DOCTYPE",9)||memmem(p,n,"<!ENTITY",8))return 0;
 for(size_t at=0;at+5<n;at++)if(!memcmp(p+at,"xmlns",5)&&(p[at+5]==':'||p[at+5]=='='||p[at+5]==' '||p[at+5]=='\t'||p[at+5]=='\n')){
  size_t q=at+5;while(q<n&&p[q]!='=')q++;if(q>=n)return 0;q++;while(q<n&&(p[q]==' '||p[q]=='\t'||p[q]=='\n'))q++;if(q>=n||(p[q]!='\"'&&p[q]!='\''))return 0;
  uint8_t quote=p[q++];size_t start=q;while(q<n&&p[q]!=quote)q++;if(q>=n)return 0;int known=0;for(int k=0;uris[k];k++)if(strlen(uris[k])==q-start&&!memcmp(p+start,uris[k],q-start))known=1;if(!known)return 0;at=q;
 }
 return 1;
}
static void jpeg_markers(JPEGState*s,int strip){
 for(jpeg_saved_marker_ptr m=s->d.marker_list;m;m=m->next){
  if(strip){
   if(m->marker==JPEG_APP0+1 && m->data_length>=6 && !memcmp(m->data,"Exif\0\0",6)){
    RCBuffer clean={0};if(rc_exif_strip(m->data,m->data_length,&clean)){jpeg_write_marker(&s->c,m->marker,clean.bytes,(unsigned)clean.size);rc_buffer_free(&clean);}else jpeg_write_marker(&s->c,m->marker,m->data,m->data_length);continue;
   }
   if(m->marker==JPEG_APP0 && m->data_length>=14 && !memcmp(m->data,"JFIF\0",5)){uint8_t jfif[14];memcpy(jfif,m->data,14);jfif[12]=jfif[13]=0;jpeg_write_marker(&s->c,m->marker,jfif,14);continue;}
   if(m->marker==JPEG_COM)continue;
   if(m->marker==JPEG_APP0+1&&m->data_length>=29&&!memcmp(m->data,"http://ns.adobe.com/xap/1.0/",28)&&xmp_can_strip(m->data,m->data_length))continue;
   if(m->marker==JPEG_APP0&&m->data_length>=5&&!memcmp(m->data,"JFXX\0",5))continue;
  }
  jpeg_write_marker(&s->c,m->marker,m->data,m->data_length);
 }
}
static void jpeg_disable_duplicate_markers(JPEGState*s){
 for(jpeg_saved_marker_ptr m=s->d.marker_list;m;m=m->next){
  if(m->marker==JPEG_APP0&&m->data_length>=5&&!memcmp(m->data,"JFIF\0",5))s->c.write_JFIF_header=FALSE;
  if(m->marker==JPEG_APP0+14&&m->data_length>=5&&!memcmp(m->data,"Adobe",5))s->c.write_Adobe_marker=FALSE;
 }
}
static int jpeg_auto_safe(const uint8_t*b,size_t n){
 JPEGState*s=jpeg_state();if(!s)return 0;
 if(setjmp(s->e.jump)){jpeg_cleanup(s);return 0;}int ok=jpeg_header(s,b,n);
 unsigned before=0,after=0;for(jpeg_saved_marker_ptr m=s->d.marker_list;m;m=m->next)before++;
 if(ok)jpeg_read_coefficients(&s->d);for(jpeg_saved_marker_ptr m=s->d.marker_list;m;m=m->next)after++;if(before!=after)ok=0;
 for(jpeg_saved_marker_ptr m=s->d.marker_list;ok&&m;m=m->next){
  if(m->marker==JPEG_COM)continue;
  if(m->marker==JPEG_APP0&&m->data_length>=5&&!memcmp(m->data,"JFIF\0",5))continue;
  if(m->marker==JPEG_APP0+1&&m->data_length>=6&&!memcmp(m->data,"Exif\0\0",6))continue;
  if(m->marker==JPEG_APP0+1&&m->data_length>=29&&!memcmp(m->data,"http://ns.adobe.com/xap/1.0/",28)&&xmp_can_strip(m->data,m->data_length))continue;
  if(m->marker==JPEG_APP0+2&&m->data_length>=12&&!memcmp(m->data,"ICC_PROFILE\0",12))continue;
  if(m->marker==JPEG_APP0+14&&m->data_length>=5&&!memcmp(m->data,"Adobe",5))continue;
  ok=0;
 }jpeg_cleanup(s);return ok;
}
static int jpeg_encode(const uint8_t*b,size_t n,int quality,int strip,RCShouldCancel cb,void*ctx,RCBuffer*out){
 JPEGState*s=jpeg_state();if(!s)return 0;
 if(setjmp(s->e.jump)){jpeg_cleanup(s);return 0;}
 if(!jpeg_header(s,b,n)){jpeg_cleanup(s);return 0;}
 jpeg_create_compress(&s->c);s->cc=1;jpeg_mem_dest(&s->c,&s->encoded,&s->encoded_size);
 if(!quality){
  jvirt_barray_ptr *coef=jpeg_read_coefficients(&s->d);jpeg_copy_critical_parameters(&s->d,&s->c);s->c.optimize_coding=TRUE;jpeg_simple_progression(&s->c);
  jpeg_disable_duplicate_markers(s);jpeg_write_coefficients(&s->c,coef);jpeg_markers(s,strip);
 }else{
  int hs[4],vs[4],components=s->d.num_components;
  for(int k=0;k<components;k++){hs[k]=s->d.comp_info[k].h_samp_factor;vs[k]=s->d.comp_info[k].v_samp_factor;}
  s->d.out_color_space=s->d.jpeg_color_space==JCS_GRAYSCALE?JCS_GRAYSCALE:JCS_RGB;jpeg_start_decompress(&s->d);
  s->c.image_width=s->d.output_width;s->c.image_height=s->d.output_height;s->c.input_components=s->d.output_components;s->c.in_color_space=s->d.out_color_space;
  jpeg_set_defaults(&s->c);if(s->d.jpeg_color_space==JCS_RGB)jpeg_set_colorspace(&s->c,JCS_RGB);s->c.density_unit=s->d.density_unit;s->c.X_density=s->d.X_density;s->c.Y_density=s->d.Y_density;jpeg_set_quality(&s->c,quality,TRUE);
  if(s->c.num_components==components)for(int k=0;k<components;k++){s->c.comp_info[k].h_samp_factor=hs[k];s->c.comp_info[k].v_samp_factor=vs[k];}
  s->c.optimize_coding=TRUE;jpeg_simple_progression(&s->c);jpeg_disable_duplicate_markers(s);jpeg_start_compress(&s->c,TRUE);jpeg_markers(s,strip);
  size_t stride=(size_t)s->d.output_width*s->d.output_components;s->pixels=malloc(stride);if(!s->pixels){jpeg_cleanup(s);return 0;}
  while(s->d.output_scanline<s->d.output_height){if(cancelled(cb,ctx)){jpeg_cleanup(s);return 0;}JSAMPROW row=s->pixels;jpeg_read_scanlines(&s->d,&row,1);jpeg_write_scanlines(&s->c,&row,1);}
 }
 jpeg_finish_compress(&s->c);jpeg_finish_decompress(&s->d);
 if(s->e.warnings || cancelled(cb,ctx)){jpeg_cleanup(s);return 0;}
 out->bytes=s->encoded;out->size=s->encoded_size;s->encoded=NULL;jpeg_cleanup(s);return 1;
}
static uint8_t *jpeg_rgba(const uint8_t*b,size_t n,int*w,int*h){
 JPEGState*s=jpeg_state();if(!s)return NULL;
 if(setjmp(s->e.jump)){jpeg_cleanup(s);return NULL;}
 if(!jpeg_header(s,b,n)){jpeg_cleanup(s);return NULL;}
 s->d.out_color_space=JCS_EXT_RGBA;jpeg_start_decompress(&s->d);*w=s->d.output_width;*h=s->d.output_height;
 size_t stride=(size_t)*w*4;s->pixels=malloc(stride* *h);if(!s->pixels){jpeg_cleanup(s);return NULL;}
 while(s->d.output_scanline<s->d.output_height){JSAMPROW row=s->pixels+stride*s->d.output_scanline;jpeg_read_scanlines(&s->d,&row,1);}jpeg_finish_decompress(&s->d);
 uint8_t*p=s->pixels;if(s->e.warnings)p=NULL;else s->pixels=NULL;jpeg_cleanup(s);return p;
}
static int similar_metrics(const uint8_t*a,const uint8_t*b,int w,int h,float threshold,float*result){
 size_t count=(size_t)w*h;for(size_t k=0;k<count;k++)if(a[k*4+3]!=b[k*4+3])return 0;
 // Use the same libwebp SSIM plane operation without importing two full ARGB
 // images. This avoids 8 bytes per pixel of duplicate picture storage.
 static const int offsets[4]={2,1,0,3};float score[5]={0};int ok=1;
 double total_distortion=0.,total_size=0.;
 for(int channel=0;channel<4;channel++){
  float distortion=0.;int offset=offsets[channel];
  if(!WebPPlaneDistortion(a+offset,(size_t)w*4,b+offset,(size_t)w*4,w,h,4,1,&distortion,&score[channel])){ok=0;break;}
  total_distortion+=distortion;total_size+=w*h;
 }
 // Match WebPPictureDistortion's aggregate and exact-similarity cap precisely.
 if(ok){double mean=total_size>0.?total_distortion/total_size:1.;score[4]=mean<1.?(float)(-10.0*log10(1.-mean)):99.f;}
 // libwebp API order is B,G,R,A,All. Alpha is separately checked for equality above.
 for(int k=0;k<3;k++)if(!isfinite(score[k])||score[k]<threshold)ok=0;
 if(result)memcpy(result,score,sizeof score);return ok;
}
int rc_rgba_ssim_rgb(const uint8_t *a,const uint8_t *b,int w,int h){
 if(!a||!b||w<=0||h<=0||w>MAX_PIXELS/h)return 0;
 return similar_metrics(a,b,w,h,SSIM_MIN_DB,NULL);
}
int rc_rgba_quality_rgb(const uint8_t *a,const uint8_t *b,int w,int h,int profile){
 if(!a||!b||w<=0||h<=0||w>MAX_PIXELS/h||!rc_profile_attempts(profile))return 0;
 return similar_metrics(a,b,w,h,rc_profile_min_ssim_db(profile),NULL);
}
int rc_jpeg_coefficients_equal(const uint8_t*a,size_t an,const uint8_t*b,size_t bn){
 JPEGState*x=jpeg_state(),*y=jpeg_state();if(!x||!y){jpeg_cleanup(x);jpeg_cleanup(y);return 0;}
 if(setjmp(x->e.jump)){jpeg_cleanup(x);jpeg_cleanup(y);return 0;}
 if(setjmp(y->e.jump)){jpeg_cleanup(x);jpeg_cleanup(y);return 0;}
 int ok=jpeg_header(x,a,an)&&jpeg_header(y,b,bn);
 if(ok)ok=x->d.image_width==y->d.image_width&&x->d.image_height==y->d.image_height&&x->d.num_components==y->d.num_components&&x->d.jpeg_color_space==y->d.jpeg_color_space;
 if(ok){jvirt_barray_ptr *xc=jpeg_read_coefficients(&x->d),*yc=jpeg_read_coefficients(&y->d);
  for(int k=0;ok&&k<x->d.num_components;k++){
   jpeg_component_info *p=&x->d.comp_info[k],*q=&y->d.comp_info[k];
   ok=p->h_samp_factor==q->h_samp_factor&&p->v_samp_factor==q->v_samp_factor&&p->width_in_blocks==q->width_in_blocks&&p->height_in_blocks==q->height_in_blocks;
   JQUANT_TBL *xt=x->d.quant_tbl_ptrs[p->quant_tbl_no],*yt=y->d.quant_tbl_ptrs[q->quant_tbl_no];if(!xt||!yt||memcmp(xt->quantval,yt->quantval,sizeof xt->quantval))ok=0;
   for(JDIMENSION r=0;ok&&r<p->height_in_blocks;r++){
    JBLOCKARRAY xr=(*x->d.mem->access_virt_barray)((j_common_ptr)&x->d,xc[k],r,1,FALSE),yr=(*y->d.mem->access_virt_barray)((j_common_ptr)&y->d,yc[k],r,1,FALSE);
    if(memcmp(xr[0],yr[0],p->width_in_blocks*sizeof(JBLOCK)))ok=0;
   }
  }
 }
 ok=ok&&!x->e.warnings&&!y->e.warnings;jpeg_cleanup(x);jpeg_cleanup(y);return ok;
}
int rc_jpeg_optimize(const uint8_t*b,size_t n,int profile,int strip,RCShouldCancel cb,void*ctx,RCBuffer*out,char*e,size_t en){
 out->bytes=NULL;out->size=0;RCBuffer best={0},trial={0};
 if(!jpeg_encode(b,n,0,strip,cb,ctx,&best)){message(e,en,cancelled(cb,ctx)?"Cancelled.":"Could not decode the complete JPEG.");return 0;}
 if(!rc_jpeg_coefficients_equal(b,n,best.bytes,best.size)){rc_buffer_free(&best);message(e,en,"The JPEG candidate does not preserve the coefficients.");return 0;}
 int attempts=rc_profile_attempts(profile);
 if(attempts&&jpeg_auto_safe(b,n)){
  for(int step=0;step<attempts&&!cancelled(cb,ctx);step++){
   if(!jpeg_encode(b,n,(int)rc_profile_quality(profile,0,step),strip,cb,ctx,&trial))break;
   if(trial.size<n&&trial.size<best.size){
    int w=0,h=0,cw=0,ch=0;uint8_t*p=jpeg_rgba(b,n,&w,&h),*q=jpeg_rgba(trial.bytes,trial.size,&cw,&ch);
    if(p&&q&&w==cw&&h==ch&&similar_metrics(p,q,w,h,rc_profile_min_ssim_db(profile),NULL)){
     rc_buffer_free(&best);best=trial;trial.bytes=NULL;trial.size=0;
    }free(p);free(q);
   }rc_buffer_free(&trial);
  }
 }
 if(cancelled(cb,ctx)||best.size>=n)rc_buffer_free(&best);*out=best;return 1;
}
static uint32_t le32(const uint8_t*p){return read32(p,1);}
static void put32(uint8_t*p,uint32_t n){p[0]=n;p[1]=n>>8;p[2]=n>>16;p[3]=n>>24;}
int rc_webp_inspect(const uint8_t*b,size_t n,RCImageInfo*i,char*e,size_t en){
 WebPBitstreamFeatures f;
 if(WebPGetFeatures(b,n,&f)!=VP8_STATUS_OK || !dimensions(f.width,f.height)){message(e,en,"Damaged WebP or unsupported dimensions.");return 0;}
 if(f.has_animation){message(e,en,"Animated WebP is not supported.");return 0;}
 WebPData data={b,n};WebPDemuxer*d=WebPDemux(&data);if(!d){message(e,en,"Incomplete WebP container.");return 0;}
 int ok=!(WebPDemuxGetI(d,WEBP_FF_FORMAT_FLAGS)&ANIMATION_FLAG)&&WebPDemuxGetI(d,WEBP_FF_FRAME_COUNT)==1;
 WebPDemuxDelete(d);if(!ok){message(e,en,"Animated WebP is not supported.");return 0;}
 i->width=f.width;i->height=f.height;i->has_alpha=f.has_alpha;i->lossless=f.format==2;return 1;
}
static int webp_unknown(const uint8_t*b,size_t n){
 if(n<12||le32(b+4)!=(n-8))return 1;
 for(size_t at=12;at+8<=n;){uint32_t count=le32(b+at+4);size_t len=8+(size_t)count+(count&1);if(len>n-at)return 1;
  if(!memcmp(b+at,"XMP ",4)&&!xmp_can_strip(b+at+8,count))return 1;
  if(memcmp(b+at,"VP8 ",4)&&memcmp(b+at,"VP8L",4)&&memcmp(b+at,"VP8X",4)&&memcmp(b+at,"ALPH",4)&&memcmp(b+at,"ICCP",4)&&memcmp(b+at,"EXIF",4)&&memcmp(b+at,"XMP ",4))return 1;
  at+=len;
 }return 0;
}
static int image_chunk(const uint8_t*p){return !memcmp(p,"VP8 ",4)||!memcmp(p,"VP8L",4)||!memcmp(p,"ALPH",4);}
/* Keep original container ordering and all unknown chunks; replace only image payloads.
 * Mux/demux APIs validate the reconstructed standard container before acceptance. */
static int webp_container(const uint8_t*src,size_t sn,const uint8_t*enc,size_t en,int strip,RCBuffer*out){
 if(sn<12||en<12||le32(src+4)!=sn-8)return 0;
 size_t cap=sn+en+4096;uint8_t*dst=malloc(cap);if(!dst)return 0;memcpy(dst,src,12);size_t used=12;int inserted=0;
 for(size_t at=12;at<sn;){if(sn-at<8){free(dst);return 0;}uint32_t count=le32(src+at+4);size_t len=8+(size_t)count+(count&1);if(len>sn-at){free(dst);return 0;}
  if(image_chunk(src+at)){
   if(!inserted){for(size_t p=12;p+8<=en;){uint32_t sz=le32(enc+p+4);size_t l=8+(size_t)sz+(sz&1);if(l>en-p){free(dst);return 0;}if(image_chunk(enc+p)){memcpy(dst+used,enc+p,l);used+=l;}p+=l;}inserted=1;}
  }else if(strip&&!memcmp(src+at,"XMP ",4)&&xmp_can_strip(src+at+8,count)){}
  else if(strip&&!memcmp(src+at,"EXIF",4)){
   RCBuffer clean={0};if(rc_exif_strip(src+at+8,count,&clean)){size_t l=clean.size;memcpy(dst+used,"EXIF",4);put32(dst+used+4,(uint32_t)l);memcpy(dst+used+8,clean.bytes,l);if(l&1)dst[used+8+l]=0;used+=8+l+(l&1);rc_buffer_free(&clean);}else {memcpy(dst+used,src+at,len);used+=len;}
  }else {memcpy(dst+used,src+at,len);if(strip&&!memcmp(dst+used,"VP8X",4)&&count>=10){dst[used+8]&=~(EXIF_FLAG|XMP_FLAG); // Restore EXIF flag when orientation requires it.
    for(size_t p=12;p+8<=sn;){uint32_t sz=le32(src+p+4);size_t l=8+(size_t)sz+(sz&1);if(l>sn-p)break;if(!memcmp(src+p,"EXIF",4))dst[used+8]|=EXIF_FLAG;if(!memcmp(src+p,"XMP ",4)&&!xmp_can_strip(src+p+8,sz))dst[used+8]|=XMP_FLAG;p+=l;}
   }used+=len;}
  at+=len;
 }
 if(!inserted){free(dst);return 0;}put32(dst+4,(uint32_t)(used-8));WebPData assembled={dst,used};WebPMux*m=WebPMuxCreate(&assembled,0);if(!m){free(dst);return 0;}int w,h;int ok=WebPMuxGetCanvasSize(m,&w,&h)==WEBP_MUX_OK;WebPMuxDelete(m);if(!ok){free(dst);return 0;}out->bytes=dst;out->size=used;return 1;
}
typedef struct { RCShouldCancel callback;void*context; } WebPCancel;
static int webp_progress(int percent,const WebPPicture*p){(void)percent;WebPCancel*c=p->user_data;return !cancelled(c->callback,c->context);}
static int webp_encode(const uint8_t*rgba,int w,int h,int lossless,float quality,RCShouldCancel cb,void*ctx,RCBuffer*out){
 WebPConfig config;if(!WebPConfigPreset(&config,WEBP_PRESET_DEFAULT,lossless?75:quality))return 0;config.lossless=lossless;config.method=4;config.exact=1;config.near_lossless=100;config.alpha_quality=100;config.thread_level=0;
 WebPPicture pic;if(!WebPPictureInit(&pic))return 0;pic.use_argb=1;pic.width=w;pic.height=h;
 WebPMemoryWriter writer;WebPMemoryWriterInit(&writer);pic.writer=WebPMemoryWrite;pic.custom_ptr=&writer;WebPCancel cancel={cb,ctx};pic.user_data=&cancel;pic.progress_hook=webp_progress;
 int ok=WebPValidateConfig(&config)&&WebPPictureImportRGBA(&pic,rgba,w*4)&&WebPEncode(&config,&pic);WebPPictureFree(&pic);
 if(ok){out->bytes=malloc(writer.size);if(out->bytes){memcpy(out->bytes,writer.mem,writer.size);out->size=writer.size;}else ok=0;}WebPMemoryWriterClear(&writer);return ok;
}
int rc_webp_pixels_equal(const uint8_t*a,size_t an,const uint8_t*b,size_t bn){int aw,ah,bw,bh;uint8_t*x=WebPDecodeRGBA(a,an,&aw,&ah),*y=WebPDecodeRGBA(b,bn,&bw,&bh);int ok=x&&y&&aw==bw&&ah==bh&&!memcmp(x,y,(size_t)aw*ah*4);WebPFree(x);WebPFree(y);return ok;}
int rc_webp_optimize(const uint8_t*b,size_t n,int profile,int strip,RCShouldCancel cb,void*ctx,RCBuffer*out,char*e,size_t en){
 out->bytes=NULL;out->size=0;RCImageInfo info={0};if(!rc_webp_inspect(b,n,&info,e,en))return 0;
 int w,h;uint8_t*p=WebPDecodeRGBA(b,n,&w,&h);if(!p){message(e,en,"Damaged or incomplete WebP.");return 0;}
 RCBuffer best={0},encoded={0},trial={0};
 if(strip && !webp_container(b,n,b,n,1,&best)){WebPFree(p);message(e,en,"Could not preserve WebP metadata.");return 0;}
 // Lossless WebP stays lossless, including RGB hidden under transparent pixels.
 int attempts=info.lossless?1:rc_profile_attempts(profile);
 if(!webp_unknown(b,n))for(int step=0;step<attempts&&!cancelled(cb,ctx);step++){
  if(!webp_encode(p,w,h,info.lossless,(float)rc_profile_quality(profile,1,step),cb,ctx,&encoded))break;
  if(webp_container(b,n,encoded.bytes,encoded.size,strip,&trial)&&trial.size<n&&(!best.bytes||trial.size<best.size)){
   int cw,ch;uint8_t*q=WebPDecodeRGBA(trial.bytes,trial.size,&cw,&ch);int valid=q&&w==cw&&h==ch;
   if(valid)valid=info.lossless?!memcmp(p,q,(size_t)w*h*4):similar_metrics(p,q,w,h,rc_profile_min_ssim_db(profile),NULL);
   if(valid){rc_buffer_free(&best);best=trial;trial.bytes=NULL;trial.size=0;}WebPFree(q);
  }rc_buffer_free(&trial);rc_buffer_free(&encoded);
 }
 WebPFree(p);if(cancelled(cb,ctx)||best.size>=n)rc_buffer_free(&best);*out=best;return 1;
}

int rc_jpeg_ssim_rgb(const uint8_t*a,size_t an,const uint8_t*b,size_t bn,float scores[5]){int w,h,cw,ch;uint8_t*p=jpeg_rgba(a,an,&w,&h),*q=jpeg_rgba(b,bn,&cw,&ch);int ok=p&&q&&w==cw&&h==ch&&similar_metrics(p,q,w,h,SSIM_MIN_DB,scores);free(p);free(q);return ok;}
int rc_webp_ssim_rgb(const uint8_t*a,size_t an,const uint8_t*b,size_t bn,float scores[5]){int w,h,cw,ch;uint8_t*p=WebPDecodeRGBA(a,an,&w,&h),*q=WebPDecodeRGBA(b,bn,&cw,&ch);int ok=p&&q&&w==cw&&h==ch&&similar_metrics(p,q,w,h,SSIM_MIN_DB,scores);WebPFree(p);WebPFree(q);return ok;}

/* Compare decompressed ICC profiles without allocating either uncompressed profile. */
int rc_zlib_equal(const uint8_t*a,size_t an,const uint8_t*b,size_t bn){
 if(an>UINT32_MAX||bn>UINT32_MAX)return 0;
 z_stream x={0},y={0};if(inflateInit(&x)!=Z_OK)return 0;if(inflateInit(&y)!=Z_OK){inflateEnd(&x);return 0;}
 x.next_in=(Bytef*)a;x.avail_in=(uInt)an;y.next_in=(Bytef*)b;y.avail_in=(uInt)bn;
 uint8_t xb[16384],yb[16384];int ok=1,xs=Z_OK,ys=Z_OK;
 while(ok&&xs!=Z_STREAM_END&&ys!=Z_STREAM_END){x.next_out=xb;x.avail_out=sizeof xb;y.next_out=yb;y.avail_out=sizeof yb;
  xs=inflate(&x,Z_NO_FLUSH);ys=inflate(&y,Z_NO_FLUSH);size_t xn=sizeof xb-x.avail_out,yn=sizeof yb-y.avail_out;
  ok=(xs==Z_OK||xs==Z_STREAM_END)&&(ys==Z_OK||ys==Z_STREAM_END)&&xn==yn&&!memcmp(xb,yb,xn)&&x.total_out<=64*1024*1024;
 }
 ok=ok&&xs==Z_STREAM_END&&ys==Z_STREAM_END&&x.total_in==an&&y.total_in==bn;inflateEnd(&x);inflateEnd(&y);return ok;
}

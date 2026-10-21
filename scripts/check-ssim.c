/* Small, deterministic regression check against the previous SSIM implementation.
 * Includes the production implementation so its static similar_metrics is tested.
 * Build/run from the project root:
 * clang -O2 -Ivendor/build/include scripts/check-ssim.c -Lvendor/build/lib
 *   -ljpeg -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lz -lm -o .build/check-ssim
 * .build/check-ssim
 */
#include "../Resim/Native/ResimCodecs.c"

static unsigned checks, accepted, rejected, alpha_rejected, near_threshold;
static float closest_above=99.f,closest_below=-1000.f;
static uint32_t random_state=0x52e51a7;
static uint32_t random_value(void){random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;return random_state;}

static int reference_metrics(const uint8_t*a,const uint8_t*b,int w,int h,float*result){
 size_t count=(size_t)w*h;for(size_t k=0;k<count;k++)if(a[k*4+3]!=b[k*4+3])return 0;
 WebPPicture p,q;WebPPictureInit(&p);WebPPictureInit(&q);p.use_argb=q.use_argb=1;p.width=q.width=w;p.height=q.height=h;
 int ok=WebPPictureImportRGBA(&p,a,w*4)&&WebPPictureImportRGBA(&q,b,w*4);float score[5]={0};
 if(ok)ok=WebPPictureDistortion(&p,&q,1,score);
 for(int k=0;k<3;k++)if(!isfinite(score[k])||score[k]<SSIM_MIN_DB)ok=0;
 if(result)memcpy(result,score,sizeof score);WebPPictureFree(&p);WebPPictureFree(&q);return ok;
}
static void compare(const uint8_t*a,const uint8_t*b,int w,int h,const char*label){
 float actual[5]={-777,-777,-777,-777,-777},reference[5]={-777,-777,-777,-777,-777};
 int expected=reference_metrics(a,b,w,h,reference),result=similar_metrics(a,b,w,h,actual);
 checks++;
 if(expected!=result||memcmp(actual,reference,sizeof actual)){
  fprintf(stderr,"SSIM mismatch %s %dx%d decision %d != %d\n",label,w,h,result,expected);
  for(int k=0;k<5;k++)fprintf(stderr,"channel%d %.9g != %.9g\n",k,actual[k],reference[k]);
  exit(1);
 }
 if(expected)accepted++;else rejected++;
 if(reference[0]==-777){alpha_rejected++;return;}
 for(int k=0;k<3;k++){
  if(reference[k]>=30.f&&reference[k]<closest_above)closest_above=reference[k];
  if(reference[k]<30.f&&reference[k]>closest_below)closest_below=reference[k];
  if(fabsf(reference[k]-30.f)<0.25f)near_threshold++;
 }
}
static void pattern(uint8_t*p,int w,int h,int kind){
 for(int y=0;y<h;y++)for(int x=0;x<w;x++){
  size_t at=((size_t)y*w+x)*4;unsigned value;
  switch(kind){
   case 0:value=0;break;
   case 1:value=255;break;
   case 2:value=127;break;
   case 3:value=(unsigned)x*255/(unsigned)w;break;
   case 4:value=(unsigned)y*255/(unsigned)h;break;
   case 5:value=((x^y)&1)?255:0;break;
   case 6:value=((x/4+y/4)&1)?230:20;break;
   default:value=random_value()&255;break;
  }
  p[at]=value;p[at+1]=(kind&1)?(uint8_t)(255-value):(uint8_t)value;
  p[at+2]=(kind&2)?(uint8_t)(value*3+11):(uint8_t)value;
  p[at+3]=kind==7?0:kind==8?(uint8_t)(x*255/w):255;
 }
}
int main(void){
 static const int sizes[][2]={{1,1},{1,7},{7,1},{2,2},{3,5},{5,3},{6,6},{7,7},{8,8},{9,13},{31,17},{32,32},{63,65},{128,97},{257,33}};
 static const unsigned amplitudes[]={0,1,2,3,4,6,8,12,20,40,100};
 for(unsigned s=0;s<sizeof sizes/sizeof sizes[0];s++){
  int w=sizes[s][0],h=sizes[s][1];size_t n=(size_t)w*h*4;
  uint8_t*a=malloc(n),*b=malloc(n);if(!a||!b)return 2;
  for(int kind=0;kind<10;kind++){
   pattern(a,w,h,kind);
   for(int channel=0;channel<3;channel++)for(unsigned v=0;v<sizeof amplitudes/sizeof amplitudes[0];v++){
    memcpy(b,a,n);
    for(size_t k=0;k<n/4;k++)if((random_value()&3)!=0){
     int value=b[k*4+channel],delta=(int)amplitudes[v];
     value+=(random_value()&1)?delta:-delta;b[k*4+channel]=(uint8_t)(value<0?0:value>255?255:value);
    }
    compare(a,b,w,h,"one RGB channel");
   }
   memcpy(b,a,n);for(size_t k=0;k<n/4;k++)for(int c=0;c<3;c++)b[k*4+c]=(uint8_t)random_value();
   compare(a,b,w,h,"all RGB channels");
   memcpy(b,a,n);b[(n/8)*4+3]^=1;compare(a,b,w,h,"alpha mismatch");
  }
  free(a);free(b);
 }
 /* Sweep sparse 1-level changes through the 30dB boundary. All dimensions stay
  * small; every decision and all five float scores must match bit-for-bit. */
 int w=64,h=48;size_t n=(size_t)w*h*4;
 uint8_t*a=malloc(n),*b=malloc(n);if(!a||!b)return 2;
 for(int value=16;value<=240;value+=32)for(int amplitude=1;amplitude<=4;amplitude++)for(int density=1;density<=64;density++){
  for(size_t k=0;k<n/4;k++){a[k*4]=a[k*4+1]=a[k*4+2]=(uint8_t)value;a[k*4+3]=255;}
  memcpy(b,a,n);
  for(size_t k=0;k<n/4;k++)if((int)(random_value()%64)<density)b[k*4]=(uint8_t)(value+((k&1)?amplitude:-amplitude));
  compare(a,b,w,h,"threshold sweep");
 }
 free(a);free(b);
 if(!accepted||!rejected||!alpha_rejected||!near_threshold||closest_below<29.9f||closest_above>30.1f){
  fprintf(stderr,"Insufficient threshold coverage: %.9g / %.9g near=%u\n",closest_below,closest_above,near_threshold);return 1;
 }
 printf("SSIM identical: %u comparisons; accepted=%u rejected=%u alpha-rejected=%u; near30dB=%u; closest=%.9g / %.9g dB\n",checks,accepted,rejected,alpha_rejected,near_threshold,closest_below,closest_above);
 return 0;
}

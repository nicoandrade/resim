#include <stdio.h>
#include <stdlib.h>
#include <jpeglib.h>
#include <string.h>
static void encode(const char *name, J_COLOR_SPACE space, int components, int progressive, int quality, int icc) {
  char path[1024]; snprintf(path,sizeof(path),"ResimTests/Fixtures/%s",name);
  struct jpeg_compress_struct c; struct jpeg_error_mgr e; c.err=jpeg_std_error(&e); jpeg_create_compress(&c);
  FILE *f=fopen(path,"wb"); if(!f)exit(1); jpeg_stdio_dest(&c,f);
  c.image_width=256;c.image_height=192;c.input_components=components;c.in_color_space=space;
  jpeg_set_defaults(&c);jpeg_set_quality(&c,quality,TRUE);
  /* Conventional 4:4:4 source to verify no subsampling degradation. */
  for(int n=0;n<c.num_components;n++){c.comp_info[n].h_samp_factor=1;c.comp_info[n].v_samp_factor=1;}
  if(progressive) jpeg_simple_progression(&c);
  jpeg_start_compress(&c,TRUE);
  if(icc){FILE *p=fopen("ResimTests/Fixtures/sRGB.icc","rb"); if(!p)exit(2); fseek(p,0,SEEK_END);long len=ftell(p);rewind(p);unsigned char *data=malloc(len);fread(data,1,len,p);fclose(p);jpeg_write_icc_profile(&c,data,(unsigned int)len);free(data);}
  unsigned char row[256*4];
  while(c.next_scanline<c.image_height){int y=c.next_scanline;for(int x=0;x<256;x++){for(int k=0;k<components;k++)row[x*components+k]=components==1?(x+y)%256:(x*(k+1)+y*(3-k))%256;}if(strstr(name,"smooth"))for(int x=0;x<256;x++){row[x*3]=40+x/2;row[x*3+1]=50+y/2;row[x*3+2]=60+(x+y)/4;}if(strstr(name,"accepted"))for(int x=0;x<256;x++)for(int k=0;k<3;k++)row[x*3+k]=100+(x/3+y/3)/8;JSAMPROW r=row;jpeg_write_scanlines(&c,&r,1);}
  jpeg_finish_compress(&c);jpeg_destroy_compress(&c);fclose(f);
}
int main(void){encode("accepted-auto.jpg",JCS_RGB,3,0,100,0);encode("smooth-auto.jpg",JCS_RGB,3,0,100,0);encode("grayscale.jpg",JCS_GRAYSCALE,1,0,95,0);encode("progressive.jpg",JCS_RGB,3,1,98,0);encode("cmyk.jpg",JCS_CMYK,4,0,95,0);encode("icc-444.jpg",JCS_RGB,3,0,100,1);encode("degraded.jpg",JCS_RGB,3,0,10,1);return 0;}

#!/usr/bin/env python3
"""Small original fixtures; no downloaded/personal images or Python dependencies."""
import binascii, pathlib, struct, zlib, random
root = pathlib.Path(__file__).resolve().parent.parent / 'ResimTests/Fixtures'
root.mkdir(parents=True, exist_ok=True)
def chunk(kind, data):
    return struct.pack('>I',len(data)) + kind + data + struct.pack('>I',binascii.crc32(kind+data)&0xffffffff)
def png(name, width, height, depth, color, rows, extra=b''):
    head = struct.pack('>IIBBBBB', width, height, depth, color, 0, 0, 0)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR',head) + extra + chunk(b'IDAT',zlib.compress(b''.join(b'\0'+r for r in rows),0)) + chunk(b'IEND',b'')
    (root/name).write_bytes(data)
    return data
w,h=192,128
rows=[]
for y in range(h):
    row=bytearray()
    for x in range(w):
        row.extend((x*255//(w-1),y*255//(h-1),(x^y)&255,0 if x<24 else (96 if x<48 else 255)))
    rows.append(bytes(row))
color = chunk(b'gAMA',struct.pack('>I',45455)) + chunk(b'sRGB',b'\0')
rgba=png('rgba.png',w,h,8,6,rows,color)
(root/'Fóto Ñ 试.PNG').write_bytes(rgba)
rows16=[b''.join(struct.pack('>HHH',x*65535//95,y*65535//63,((x+y)*503)%65536) for x in range(96)) for y in range(64)]
png('rgb16.png',96,64,16,2,rows16,color)
palette=bytes([240,40,30,20,180,90,35,80,235,255,240,40])
png('palette.png',96,64,8,3,[bytes((x//8+y//8)%4 for x in range(96)) for y in range(64)],chunk(b'PLTE',palette)+chunk(b'tRNS',bytes([255,192,0,255])))
# Valid one-frame APNG; must still be excluded as animated container.
control=chunk(b'acTL',struct.pack('>II',1,0))+chunk(b'fcTL',struct.pack('>IIIIIHHBB',0,w,h,0,0,1,10,0,0))
png('animated.png',w,h,8,6,rows,control)
rng=random.Random(20261020)
landscape=[]
for y in range(256):
    row=bytearray()
    for x in range(384):
        noise=rng.randrange(-9,10)
        mountain = y > 125 + 35 * ((x%127)/127) - (x%53)/3
        rgb=(70+x//5+noise,125+y//5+noise,205-y//4+noise) if not mountain else (35+x//8+noise,80+y//4+noise,42+y//8+noise)
        row.extend(max(0,min(255,c)) for c in rgb)
    landscape.append(bytes(row))
png('landscape.png',384,256,8,2,landscape,color)
png('fine-lines.png',256,128,8,2,[bytes(c for x in range(256) for c in ((0,0,0) if x%3==0 or y%7==0 else (255,255,255))) for y in range(128)],color)
(root/'corrupt.png').write_bytes(rgba[:64])
(root/'not-image.jpg').write_text('Not an image. Original Resim test fixture.\n')
print(root)

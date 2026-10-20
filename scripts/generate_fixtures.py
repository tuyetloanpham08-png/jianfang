#!/usr/bin/env python3
"""Generate the sample media referenced by the committed JSON/SRT projects.

Usage: python3 scripts/generate_fixtures.py [--output-dir NEW_DIRECTORY]
The default output is fixtures/media. No project, report, or manifest is written.
All planned outputs must be absent; existing files are never replaced.
Requires Python 3 and FFmpeg with libx264/libx265. The app does not require them.
"""
from __future__ import annotations
import argparse, array, binascii, math, pathlib, shutil, struct, subprocess, sys, wave, zlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'fixtures'
MEDIA = OUT / 'media'
FPS, SR, SOURCE_SECONDS = 30, 48000, 20
FONT = {
'0':['01110','10001','10011','10101','11001','10001','01110'],
'1':['00100','01100','00100','00100','00100','00100','01110'],
'2':['01110','10001','00001','00010','00100','01000','11111'],
'3':['11110','00001','00001','01110','00001','00001','11110'],
'4':['00010','00110','01010','10010','11111','00010','00010'],
'5':['11111','10000','10000','11110','00001','00001','11110'],
'6':['01110','10000','10000','11110','10001','10001','01110'],
'7':['11111','00001','00010','00100','01000','01000','01000'],
'8':['01110','10001','10001','01110','10001','10001','01110'],
'9':['01110','10001','10001','01111','00001','00001','01110'],
'A':['01110','10001','10001','11111','10001','10001','10001'],
'B':['11110','10001','10001','11110','10001','10001','11110'],
'C':['01111','10000','10000','10000','10000','10000','01111'],
'D':['11110','10001','10001','10001','10001','10001','11110'],
'E':['11111','10000','10000','11110','10000','10000','11111'],
'F':['11111','10000','10000','11110','10000','10000','10000'],
'G':['01111','10000','10000','10111','10001','10001','01111'],
'H':['10001','10001','10001','11111','10001','10001','10001'],
'I':['11111','00100','00100','00100','00100','00100','11111'],
'J':['00111','00010','00010','00010','00010','10010','01100'],
'K':['10001','10010','10100','11000','10100','10010','10001'],
'L':['10000','10000','10000','10000','10000','10000','11111'],
'M':['10001','11011','10101','10101','10001','10001','10001'],
'N':['10001','11001','10101','10011','10001','10001','10001'],
'O':['01110','10001','10001','10001','10001','10001','01110'],
'P':['11110','10001','10001','11110','10000','10000','10000'],
'Q':['01110','10001','10001','10001','10101','10010','01101'],
'R':['11110','10001','10001','11110','10100','10010','10001'],
'S':['01111','10000','10000','01110','00001','00001','11110'],
'T':['11111','00100','00100','00100','00100','00100','00100'],
'U':['10001','10001','10001','10001','10001','10001','01110'],
'V':['10001','10001','10001','10001','10001','01010','00100'],
'W':['10001','10001','10001','10101','10101','10101','01010'],
'X':['10001','10001','01010','00100','01010','10001','10001'],
'Y':['10001','10001','01010','00100','00100','00100','00100'],
'Z':['11111','00001','00010','00100','01000','10000','11111'],
' ':['00000']*7, '/':['00001','00001','00010','00100','01000','10000','10000'],
'-':['00000','00000','00000','11111','00000','00000','00000'],
}

def run(args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)

def chunk(kind, data):
    return struct.pack('>I',len(data)) + kind + data + struct.pack('>I',binascii.crc32(kind+data)&0xffffffff)

def write_png(path, w, h, pixels, srgb=True):
    raw=b''.join(b'\0'+pixels[y*w*3:(y+1)*w*3] for y in range(h))
    data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+(chunk(b'sRGB',b'\0') if srgb else b'')+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b'')
    with path.open('xb') as output: output.write(data)

def rect(pixels,w,h,x,y,rw,rh,color):
    for j in range(max(0,y), min(h,y+rh)):
        x1,x2=max(0,x), min(w,x+rw)
        if x2>x1: pixels[(j*w+x1)*3:(j*w+x2)*3]=bytes(color)*(x2-x1)

def text(pixels,w,h,x,y,value,scale=6,color=(255,255,255)):
    for i,ch in enumerate(value):
        for row,bits in enumerate(FONT[ch]):
            for col,bit in enumerate(bits):
                if bit=='1': rect(pixels,w,h,x+i*6*scale+col*scale,y+row*scale,scale,scale,color)

def graphics():
    backgrounds=[(30,70,160),(180,50,35),(30,130,70)]
    for index,bg in enumerate(backgrounds,1):
        w,h=1280,720;p=bytearray(bytes(bg)*(w*h))
        rect(p,w,h,8,8,w-16,8,(255,255,255));rect(p,w,h,8,h-16,w-16,8,(255,255,255))
        rect(p,w,h,8,8,8,h-16,(255,255,255));rect(p,w,h,w-16,8,8,h-16,(255,255,255))
        for x,y,c in [(24,24,(255,0,0)),(1176,24,(0,255,0)),(24,616,(0,0,255)),(1176,616,(255,255,0))]:rect(p,w,h,x,y,80,80,c)
        text(p,w,h,160,55,'TOP / SOURCE '+str(index).zfill(2),7)
        text(p,w,h,460,270,str(index).zfill(2),28)
        text(p,w,h,55,370,'LEFT',5);text(p,w,h,1060,370,'RIGHT',5)
        text(p,w,h,350,640,'BOTTOM / 30 FPS',6)
        # Rightward orientation arrow, independent of text.
        rect(p,w,h,420,505,440,12,(255,255,255))
        for k in range(70): rect(p,w,h,790+k,441+k,6,140-2*k,(255,255,255))
        write_png(MEDIA/f'source{index:02d}.png',w,h,p)
        def bt709_code(v):
            c=v/255; linear=c/12.92 if c<=.04045 else ((c+.055)/1.055)**2.4
            encoded=4.5*linear if linear<.018 else 1.099*linear**.45-.099
            return min(255,max(0,round(encoded*255)))
        lut=bytes(bt709_code(v) for v in range(256))
        # Intermediate RGB values have BT.709 transfer, so deliberately omit sRGB metadata.
        write_png(MEDIA/f'source{index:02d}-bt709-rgb.png',w,h,bytes(p).translate(lut),srgb=False)
    w,h=1200,600;p=bytearray(w*h*3)
    swatches=[(0,0,0),(32,32,32),(64,64,64),(128,128,128),(192,192,192),(255,255,255),(255,0,0),(0,255,0),(0,0,255),(255,255,0),(0,255,255),(255,0,255)]
    entries=[]
    for n,c in enumerate(swatches):
        x,y=(n%6)*200,(n//6)*300
        rect(p,w,h,x,y,200,300,c)
        entries.append({'index':n,'pixelCenter':[x+100,y+150],'sRGB8':list(c)})
    write_png(MEDIA/'srgb-chart.png',w,h,p)
    return backgrounds,entries

def audio():
    for index,freq in enumerate([220,330,440,550],1):
        samples=array.array('h')
        for i in range(SR*SOURCE_SECONDS):
            t=i/SR
            value=.03*math.sin(2*math.pi*freq*t)
            if index==1 and any(start<=t<start+.1 for start in [.2,10,19.8]):
                value+=.22*math.sin(2*math.pi*1000*t)
            v=round(value*32767);samples.extend([v,v])
        if sys.byteorder!='little':samples.byteswap()
        with (MEDIA/f'tone{index:02d}.wav').open('xb') as raw:
            with wave.open(raw,'wb') as out:
                out.setnchannels(2);out.setsampwidth(2);out.setframerate(SR);out.writeframes(samples.tobytes())

def media(ffmpeg):
    def common():return [ffmpeg,'-nostdin','-hide_banner','-loglevel','warning','-n']
    for index in range(1,4):
        # Moving white bar at y=560 plus full-frame flashes; flash timing is fixed by frame number.
        filt="[0:v][1:v]overlay=x='mod(n*7,1184)':y=560:eval=frame:format=rgb,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(n,6,8)+between(n,300,302)+between(n,594,596)',scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv[v]"
        run(common()+['-loop','1','-framerate','30','-i',str(MEDIA/f'source{index:02d}-bt709-rgb.png'),'-f','lavfi','-i','color=c=white:s=96x24:r=30','-i',str(MEDIA/'tone01.wav'),'-filter_complex',filt,'-map','[v]','-map','2:a','-t','20','-r','30','-c:v','libx264','-preset','veryfast','-crf','18','-g','30','-pix_fmt','yuv420p','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-c:a','aac','-b:a','192k','-ar','48000','-movflags','+faststart',str(MEDIA/f'source{index:02d}.mp4')])
    run(common()+['-i',str(MEDIA/'srgb-chart.png'),'-frames:v','1','-q:v','1','-update','1',str(MEDIA/'srgb-chart.jpg')])
    for fps in [24,25]:
        run(common()+['-loop','1','-framerate',str(fps),'-i',str(MEDIA/'source01-bt709-rgb.png'),'-vf','scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv','-t','2','-c:v','libx264','-preset','veryfast','-crf','18','-g',str(fps),'-pix_fmt','yuv420p','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-an','-movflags','+faststart',str(MEDIA/f'cfr{fps}.mp4')])

def sampling_media(ffmpeg):
    """Generate frame-coded CFR and container-rotation inputs."""
    for fps in [24,25]:
        w,h=1280,720
        path=MEDIA/f'barcode-cfr{fps}.mp4'
        command=[ffmpeg,'-nostdin','-hide_banner','-loglevel','warning','-n','-f','rawvideo','-pix_fmt','rgb24','-s','1280x720','-r',str(fps),'-i','pipe:0','-vf','scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv','-frames:v',str(fps*3),'-c:v','libx264','-preset','veryfast','-crf','14','-g',str(fps),'-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-an','-movflags','+faststart',str(path)]
        proc=subprocess.Popen(command,stdin=subprocess.PIPE)
        def bt709_code(v):
            c=v/255;linear=c/12.92 if c<=.04045 else ((c+.055)/1.055)**2.4
            return min(255,max(0,round(255*(4.5*linear if linear<.018 else 1.099*linear**.45-.099))))
        lut=bytes(bt709_code(v) for v in range(256))
        for frame in range(fps*3):
            bg=(35,65,130) if fps==24 else (145,65,35)
            pixels=bytearray(bytes(bg)*(w*h))
            text(pixels,w,h,80,60,f'CFR {fps} / FRAME {frame:02d}',7)
            text(pixels,w,h,80,350,'TOP / BINARY FRAME ID',6)
            text(pixels,w,h,80,630,'BOTTOM / RIGHT',6)
            rect(pixels,w,h,64,192,32,96,(255,255,255))
            rect(pixels,w,h,672,192,32,96,(255,255,255))
            for bit in range(8):
                v=255 if frame & (1<<(7-bit)) else 0
                rect(pixels,w,h,128+bit*64,192,64,96,(v,v,v))
            rect(pixels,w,h,(frame*13)%1184,500,96,24,(255,255,255))
            for x,y,c in [(8,8,(255,0,0)),(1216,8,(0,255,0)),(8,656,(0,0,255)),(1216,656,(255,255,0))]:rect(pixels,w,h,x,y,56,56,c)
            proc.stdin.write(bytes(pixels).translate(lut))
        proc.stdin.close()
        if proc.wait()!=0:raise RuntimeError(f'Encoding {path.name} failed')
    rotated=MEDIA/'barcode-cfr24-rotate90.mp4'
    run([ffmpeg,'-nostdin','-hide_banner','-loglevel','warning','-n','-display_rotation:v:0','90','-i',str(MEDIA/'barcode-cfr24.mp4'),'-c','copy',str(rotated)])

def boundary_media(ffmpeg):
    """Generate synthetic image, audio, codec and invalid-file inputs."""
    w,h=200,100;pixels=bytearray(w*h*4)
    for y in range(30,70):
        for x in range(20,60):pixels[(y*w+x)*4:(y*w+x+1)*4]=bytes((255,255,255,255))
    raw=b''.join(b'\0'+pixels[y*w*4:(y+1)*w*4] for y in range(h))
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'sRGB',b'\0')+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b'')
    with (MEDIA/'offset-white-square.png').open('xb') as output: output.write(png)
    mono=MEDIA/'mono44100-660hz.wav'
    samples=array.array('h',(round(.08*32767*math.sin(2*math.pi*660*n/44100)) for n in range(3*44100)))
    if sys.byteorder!='little':samples.byteswap()
    with mono.open('xb') as raw:
        with wave.open(raw,'wb') as out:out.setnchannels(1);out.setsampwidth(2);out.setframerate(44100);out.writeframes(samples.tobytes())
    common=[ffmpeg,'-nostdin','-hide_banner','-loglevel','warning','-n']
    run(common+['-i',str(mono),'-c:a','aac','-b:a','128k','-ar','44100','-ac','1',str(MEDIA/'mono44100-660hz.m4a')])
    with (MEDIA/'reject-corrupt.mp4').open('xb') as output:
        output.write(b'\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2BROKEN_NO_MOOV_OR_SAMPLES\x00')
    run(common+['-f','lavfi','-i','color=c=blue:s=320x180:r=30:d=1','-c:v','mpeg4','-q:v','4','-an',str(MEDIA/'reject-mpeg4.mp4')])
    run(common+['-f','lavfi','-i','color=c=red:s=320x180:r=30:d=1','-vf','format=yuv420p10le','-c:v','libx265','-preset','ultrafast','-x265-params','log-level=error:pools=1:frame-threads=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1','-color_range','tv','-colorspace','bt2020nc','-color_primaries','bt2020','-color_trc','smpte2084','-an',str(MEDIA/'reject-hdr-hevc10.mp4')])
    run(common+['-f','lavfi','-i','testsrc2=s=320x180:r=30:d=1','-vf',"settb=1/90000,setpts='N*3000+if(eq(mod(N,2),1),1500,0)'",'-fps_mode','vfr','-enc_time_base','1:90000','-c:v','libx264','-preset','veryfast','-pix_fmt','yuv420p','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-an',str(MEDIA/'reject-vfr.mp4')])


OUTPUT_NAMES = [
    *[f'source{i:02d}{suffix}' for i in range(1,4) for suffix in ['.png','-bt709-rgb.png','.mp4']],
    *[f'tone{i:02d}.wav' for i in range(1,5)],
    'srgb-chart.png','srgb-chart.jpg','cfr24.mp4','cfr25.mp4',
    'barcode-cfr24.mp4','barcode-cfr25.mp4','barcode-cfr24-rotate90.mp4',
    'offset-white-square.png','mono44100-660hz.wav','mono44100-660hz.m4a',
    'reject-corrupt.mp4','reject-mpeg4.mp4','reject-hdr-hevc10.mp4','reject-vfr.mp4',
]


def main():
    global MEDIA
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',type=pathlib.Path,default=MEDIA,help='New media output directory; default: fixtures/media')
    args=parser.parse_args();MEDIA=args.output_dir.expanduser().resolve()
    if MEDIA.exists() and not MEDIA.is_dir():raise SystemExit('Output path is not a directory.')
    existing=[name for name in OUTPUT_NAMES if (MEDIA/name).exists() or (MEDIA/name).is_symlink()]
    if existing:raise SystemExit('Refusing to replace existing files: '+', '.join(existing))
    ffmpeg=shutil.which('ffmpeg')
    if not ffmpeg:raise SystemExit('FFmpeg is required only to generate test media.')
    encoders=subprocess.check_output([ffmpeg,'-hide_banner','-encoders'],text=True,stderr=subprocess.DEVNULL)
    if not all(codec in encoders for codec in ['libx264','libx265']):raise SystemExit('FFmpeg must include libx264 and libx265.')
    MEDIA.mkdir(parents=True,exist_ok=True)
    graphics();audio();media(ffmpeg);sampling_media(ffmpeg);boundary_media(ffmpeg)
    print(f'Generated {len(OUTPUT_NAMES)} synthetic media files. Project JSON/SRT files were not changed.')


if __name__=='__main__':main()

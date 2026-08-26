#!/usr/bin/env python3
"""Makes each Game & Watch simulator reveal where its buttons are drawn.

Marcus's overnight ask, 2026-08-25: no controller, tap the buttons on
the artwork itself, "as if I were really playing the game back in the
day," hard-coded data rather than editor content. The simulators ignore
the libretro pointer (proven with bench -tap), so taps must synthesize
JOYPAD presses, which means knowing where each drawn button sits. Nobody
hand-maps 59 games: every sim draws its button PRESSED when the mapped
input is held, so pressing each input in the headless bench and diffing
frames against an unpressed run recovers the button's own pixels.

Per game:
 1. Find a frame where input registers (the MADrigal splash eats input):
    press START at increasing frames until the output diverges.
 2. Build an animation mask from the unpressed run, frames F and F+HOLD,
    so clocks and demo motion cannot masquerade as buttons.
 3. For each retropad id, diff pressed frame F+HOLD-1 against the
    unpressed one, drop masked pixels, and keep the bounding box if what
    remains looks like a button rather than gameplay fallout.
 4. Emit JSON: file -> {width, height, orientation, buttons: {id: rect}}.
    Orientation is the artwork's own: wider than tall plays landscape.

Run: python3 tools/lab/gw/extract_hotspots.py <mgw-dir> <out.json>
"""
import json, os, subprocess, sys, tempfile

BENCH = 'tools/lab/bench/libretro_bench'
CORE = 'spikes/cores/gw/src/gw_libretro.dylib'
# Direct game inputs only. select and start are the framework's hand
# menu (pressing select just draws the hand, which the first pass
# mistook for a button), and the shoulder ids are either consumed by
# the menu or covered by the source-geometry pass in extract_menu.py.
IDS = {0:'b',1:'y',4:'up',5:'down',6:'left',7:'right',8:'a',9:'x'}
HOLD = 24

def read_ppm(path):
    d = open(path,'rb').read()
    assert d[:2]==b'P6'
    i=2; vals=[]
    while len(vals)<3:
        while d[i] in b' \t\r\n': i+=1
        if d[i:i+1]==b'#':
            while d[i] not in b'\r\n': i+=1
            continue
        j=i
        while d[j] not in b' \t\r\n': j+=1
        vals.append(int(d[i:j])); i=j
    w,h,_=vals
    return w,h,d[i+1:i+1+w*h*3]

def run(mgw, frames, dumps, presses, outdir):
    os.makedirs(outdir, exist_ok=True)
    cmd=[BENCH, CORE, mgw, '-f', str(frames), '-s', '/tmp/gwsys',
         '-d', outdir, '--dump-at', ','.join(map(str,dumps))]
    for p in presses: cmd += ['-i', p]
    r=subprocess.run(cmd, capture_output=True, text=True)
    out={}
    for d in dumps:
        p=os.path.join(outdir, 'frame-%06d.ppm'%d)
        if os.path.exists(p): out[d]=read_ppm(p)
    return out

def diff_mask(a, b, thresh=24):
    w,h,pa=a[0],a[1],a[2]; pb=b[2]
    m=bytearray(w*h)
    for i in range(w*h):
        j=i*3
        if abs(pa[j]-pb[j])+abs(pa[j+1]-pb[j+1])+abs(pa[j+2]-pb[j+2])>thresh:
            m[i]=1
    return m

def bbox(mask,w,h,skip=None):
    x0=y0=1<<30; x1=y1=-1; n=0
    for y in range(h):
        row=y*w
        for x in range(w):
            if mask[row+x] and not (skip and skip[row+x]):
                n+=1
                if x<x0:x0=x
                if x>x1:x1=x
                if y<y0:y0=y
                if y>y1:y1=y
    return (x0,y0,x1,y1,n) if n else None

def extract(mgw):
    name=os.path.basename(mgw)
    with tempfile.TemporaryDirectory() as td:
        # 1. when does input register? Probe START at growing frames and
        # compare WHOLE-RUN hashes, not one dumped frame: Egg responds to
        # a press but takes longer than the hold to show it on screen,
        # and the single-frame check called the game dead.
        def out_hash(presses, frames):
            cmd=[BENCH, CORE, mgw, '-f', str(frames), '-s', '/tmp/gwsys']
            for pr in presses: cmd += ['-i', pr]
            r=subprocess.run(cmd, capture_output=True, text=True)
            for line in r.stdout.splitlines():
                if 'output_hash' in line: return line
            return ''
        ready=None
        for probe in (240, 480, 720, 1080, 1500, 2400, 3600):
            if out_hash([], probe+120) != out_hash(['%d,3,%d'%(probe,HOLD)], probe+120):
                ready=probe; break
        if ready is None:
            return None, 'input never registered (probed to 3600)'
        f=ready+HOLD-2
        f2=f+HOLD
        # Both mask frames sit AFTER the splash: Egg resizes its frame
        # when the splash ends, and a mask built across that boundary
        # compared two different geometries.
        b1=run(mgw, f2+1, [f, f2], [], td+'/m1')
        if f not in b1 or f2 not in b1: return None, 'baseline dump failed'
        w,h,_=b1[f]
        if b1[f2][0]!=w or b1[f2][1]!=h: return None, 'frame size unstable at ready point'
        anim=diff_mask(b1[f], b1[f2])
        # widen the animation mask a pixel so antialiased digit edges
        # do not leak through
        wide=bytearray(anim)
        for y in range(1,h-1):
            for x in range(1,w-1):
                i=y*w+x
                if anim[i]:
                    for dy in (-1,0,1):
                        for dx in (-1,0,1): wide[i+dy*w+dx]=1
        spots={}
        for rid,rname in IDS.items():
            os.makedirs(td+'/r%d'%rid,exist_ok=True)
            pr=run(mgw, f+1, [f], ['%d,%d,%d'%(ready,rid,HOLD)], td+'/r%d'%rid)
            if f not in pr: continue
            # A press can change the frame geometry itself (a sim
            # zooming on input); different sizes cannot diff.
            if pr[f][0]!=w or pr[f][1]!=h: continue
            m=diff_mask(b1[f], pr[f])
            bb=bbox(m,w,h,skip=wide)
            if not bb: continue
            x0,y0,x1,y1,n=bb
            bw,bh=x1-x0+1,y1-y0+1
            # A button is compact. Gameplay fallout (the demo reacting)
            # sprawls; reject boxes bigger than a fifth of the panel or
            # nearly empty ones.
            if bw>w/4 or bh>h/4 or n<30: continue
            spots[rname]=[x0,y0,bw,bh]
        if not spots:
            return None, 'no button pixels found'
        return {'width':w,'height':h,
                'orientation':'landscape' if w>=h else 'portrait',
                'ready_hint':ready,'buttons':spots}, None

def main():
    mgwdir,outp=sys.argv[1],sys.argv[2]
    out={}; fails=[]
    files=sorted(f for f in os.listdir(mgwdir) if f.endswith('.mgw'))
    for i,fn in enumerate(files):
        spec,err=extract(os.path.join(mgwdir,fn))
        if spec: out[fn]=spec; print('%2d/%d  %-52s %d buttons'%(i+1,len(files),fn[:52],len(spec['buttons'])))
        else: fails.append((fn,err)); print('%2d/%d  %-52s FAIL %s'%(i+1,len(files),fn[:52],err))
    json.dump(out,open(outp,'w'),indent=1,sort_keys=True)
    print('\n%d mapped, %d failed'%(len(out),len(fails)))
    for fn,e in fails: print('   FAIL',fn,e)

if __name__=='__main__': main()

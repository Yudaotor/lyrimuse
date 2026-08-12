import json, io, os, os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

SP = os.environ.get('SIMEVAL_DATA') or os.path.dirname(os.path.abspath(__file__))
OUT = SP + '/simruns'
os.makedirs(OUT, exist_ok=True)
BIN = '/Applications/Lyrimuse.app/Contents/Resources/collector'
tracks = json.load(io.open(SP + '/dataset.json'))

def safe(s):
    return ''.join(ch if ch.isalnum() else '_' for ch in s)[:60]

def run(i_t):
    i, t = i_t
    out = OUT + '/%03d_%s.json' % (i, safe(t['artist'] + '-' + t['title']))
    if os.path.exists(out):
        return 'skip'
    try:
        p = subprocess.run(
            [BIN, 'search-lyrics', '-artist', t['artist'], '-title', t['title'],
             '-album', t['album'], '-duration', str(t['duration'])],
            capture_output=True, text=True, timeout=40)
        lines = [l for l in p.stdout.splitlines() if l.strip()]
        final = json.loads(lines[-1]) if lines else {}
    except Exception as e:
        final = {'error': '%s: %s' % (type(e).__name__, e)}
    rec = {'track': t, 'result': final}
    io.open(out, 'w', encoding='utf-8').write(json.dumps(rec, ensure_ascii=False))
    return 'ok'

t0 = time.time()
with ThreadPoolExecutor(max_workers=3) as ex:
    n = 0
    for r in ex.map(run, enumerate(tracks)):
        n += 1
        if n % 20 == 0:
            print('%d/%d  %.0fs' % (n, len(tracks), time.time() - t0), flush=True)
print('DONE %d tracks in %.0fs' % (len(tracks), time.time() - t0))

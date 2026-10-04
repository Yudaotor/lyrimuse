import json, io, os, re, time, urllib.request, unicodedata, statistics, glob

SP = os.environ.get('SIMEVAL_DATA') or os.path.dirname(os.path.abspath(__file__))

def norm(s):
    s = unicodedata.normalize('NFKC', s or '').casefold()
    return ''.join(ch for ch in s if ch.isalnum())

# --- 1. lyrics 文件夹:当前流水线的选择(权威 6 字段) ---
tracks = {}
for p in glob.glob(os.path.expanduser('~/.config/lyrimuse/lyrics/*.lrc')):
    try:
        head = io.open(p, encoding='utf-8', errors='replace').read(2000)
    except Exception:
        continue
    def tag(t):
        m = re.search(r'^\[' + t + r':(.*?)\]\s*$', head, re.M)
        return m.group(1).strip() if m else ''
    ar, ti, al, src = tag('ar'), tag('ti'), tag('al'), tag('source')
    if not ti:
        continue
    key = norm(ar) + '|' + norm(ti)
    tracks[key] = {'artist': ar, 'title': ti, 'album': al, 'chosen_source': src,
                   'lrc_file': os.path.basename(p)}
print('lyrics folder tracks:', len(tracks))

# --- 2. ListenBrainz 拉听歌记录取 duration_ms ---
cfg = json.load(io.open(os.path.expanduser('~/.config/lyrimuse/config.json')))
tok, lbuser = cfg['listenbrainz_token'], cfg['listenbrainz_user']
durs = {}   # key -> [secs...]
max_ts = None
fetched = 0
for page in range(40):
    url = 'https://api.listenbrainz.org/1/user/%s/listens?count=100' % lbuser
    if max_ts: url += '&max_ts=%d' % max_ts
    req = urllib.request.Request(url, headers={'Authorization': 'Token ' + tok})
    try:
        d = json.load(urllib.request.urlopen(req, timeout=15))
    except Exception as e:
        print('LB fetch stop:', type(e).__name__, e); break
    ls = d.get('payload', {}).get('listens', [])
    if not ls: break
    fetched += len(ls)
    for l in ls:
        tm = l.get('track_metadata', {})
        ai = tm.get('additional_info', {})
        dm = ai.get('duration_ms')
        if not dm: continue
        key = norm(tm.get('artist_name','')) + '|' + norm(tm.get('track_name',''))
        durs.setdefault(key, []).append(dm/1000.0)
    max_ts = min(l['listened_at'] for l in ls) - 1
    time.sleep(0.3)
print('LB listens fetched:', fetched, 'unique with duration:', len(durs))

# --- 3. join ---
joined = []
for key, t in tracks.items():
    if key in durs:
        t['duration'] = round(statistics.median(durs[key]), 1)
        t['key'] = key
        joined.append(t)
print('joined (track + duration):', len(joined))
io.open(SP + '/dataset.json', 'w', encoding='utf-8').write(json.dumps(joined, ensure_ascii=False, indent=1))

# 顺带统计当前选择的来源分布
from collections import Counter
print('chosen source dist:', Counter(t['chosen_source'] for t in joined))

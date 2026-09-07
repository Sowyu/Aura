import sys, json
D = sys.argv[1]
finds = {}; verdicts = {}
# journal: result entries carry agentId; pair by order: finder results have 'findings', verifier results have 'verdicts'.
# Verifier results do not name their area, so match by finding ids.
for line in open(D + '/journal.jsonl'):
    try: j = json.loads(line)
    except: continue
    if j.get('type') != 'result': continue
    r = j.get('result')
    if not isinstance(r, dict): continue
    if 'findings' in r: finds[r['area']] = r
    elif 'verdicts' in r:
        ids = [v['id'] for v in r['verdicts']]
        area = ids[0].rsplit('-', 1)[0] if ids else None
        if area: verdicts[area] = r
out = {}
for area, r in finds.items():
    v = verdicts.get(area)
    kept, dropped = [], []
    if v is None:
        kept = [dict(f, verified=False) for f in r['findings']]
    else:
        by = {x['id']: x for x in v['verdicts']}
        for f in r['findings']:
            x = by.get(f['id'])
            if x and x['keep']:
                kept.append(dict(f, severity=x['severity'], fix=(x['fix_adjustment'] or f['fix']), verify_reason=x['reason'], verified=True))
            else:
                dropped.append({'id': f['id'], 'title': f['title'], 'reason': x['reason'] if x else 'no verdict'})
        for i, m in enumerate(v.get('missed', [])):
            m = dict(m); 
            if not m.get('id') or m['id'] in by: m['id'] = f"{area}-missed-{i+1}"
            kept.append(dict(m, verified=True, from_skeptic=True))
    out[area] = {'area': area, 'summary': r.get('summary',''), 'kept': kept, 'dropped': dropped}
json.dump(out, open('polish/findings-verified.json', 'w'), indent=1)
tk = sum(len(a['kept']) for a in out.values()); td = sum(len(a['dropped']) for a in out.values())
print('areas', len(out), 'verified areas', len(verdicts), 'kept', tk, 'dropped', td)
for a in out.values():
    print(f"  {a['area']:20} kept {len(a['kept']):3} dropped {len(a['dropped']):2}  from_skeptic {sum(1 for k in a['kept'] if k.get('from_skeptic'))}")
    for d in a['dropped']: print('      dropped', d['id'], '|', d['reason'][:120])

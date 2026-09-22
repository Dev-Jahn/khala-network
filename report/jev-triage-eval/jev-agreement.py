#!/usr/bin/env python3
"""Agreement between blind labels (jev-labels.tsv) and Jev answers (jev-corpus/NN.jev.json)."""
import json, os, csv
S = os.path.dirname(os.path.abspath(__file__))
labels = {r['id']: r for r in csv.DictReader(open(S + '/jev-labels.tsv'), delimiter='\t')}
rows = []
for i, lab in sorted(labels.items()):
    p = f'{S}/jev-corpus/{i}.jev.json'
    if not os.path.exists(p): continue
    a = json.load(open(p))['answers']
    rows.append((i, lab, a))
print(f'n={len(rows)}')
def binstats(key, jkey, thr):
    tp=fp=fn=tn=0
    for i, lab, a in rows:
        y = lab[key] == 'yes'; p = a[jkey]['noul'] >= thr
        tp += y and p; fp += (not y) and p; fn += y and (not p); tn += (not y) and (not p)
    acc = (tp+tn)/len(rows); prec = tp/(tp+fp) if tp+fp else float('nan'); rec = tp/(tp+fn) if tp+fn else float('nan')
    return acc, prec, rec, tp, fp, fn, tn
for key in ('needs_action', 'awaits_reply', 'time_sensitive'):
    print(f'\n{key}: yes={sum(l[key]=="yes" for _,l,_ in rows)}')
    for thr in (0.3, 0.4, 0.5, 0.6, 0.7):
        acc, prec, rec, tp, fp, fn, tn = binstats(key, key, thr)
        print(f'  thr {thr:.1f}: acc {acc:.2f} prec {prec:.2f} rec {rec:.2f}  (tp{tp} fp{fp} fn{fn} tn{tn})')
print('\nkind:')
kinds = ['question','request','report','info','ack']
conf = {}
ok = 0
for i, lab, a in rows:
    g = lab['kind']; p = a['kind']['choice']; ok += g == p
    conf.setdefault(g, {}).setdefault(p, 0); conf[g][p] += 1
print(f'  accuracy {ok/len(rows):.2f}')
print('  gold\\jev ' + ' '.join(f'{k:>8}' for k in kinds))
for g in kinds:
    if g in conf: print(f'  {g:<9} ' + ' '.join(f'{conf[g].get(p,0):>8}' for p in kinds))
print('\nkind accuracy by confidence:')
for lo, hi in ((0,0.5),(0.5,0.8),(0.8,1.01)):
    sel = [(lab['kind']==a['kind']['choice']) for _,lab,a in rows if lo <= a['kind']['confidence'] < hi]
    if sel: print(f'  conf [{lo},{hi}): n={len(sel)} acc={sum(sel)/len(sel):.2f}')
# collapsed: actionable (question|request) vs not
ok2 = sum((lab['kind'] in ('question','request')) == (a['kind']['choice'] in ('question','request')) for _,lab,a in rows)
print(f'\nactionable-vs-not (kind collapsed): acc {ok2/len(rows):.2f}')
print('\ndisagreements (kind):')
for i, lab, a in rows:
    if lab['kind'] != a['kind']['choice']:
        print(f"  {i} gold={lab['kind']:<8} jev={a['kind']['choice']:<8} conf={a['kind']['confidence']:.2f} action={a['needs_action']['noul']:.2f} | {lab['note']}")

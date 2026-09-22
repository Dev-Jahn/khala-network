#!/usr/bin/env python3
"""Run the v1 triage question set over the sampled letters; cache one JSON per letter."""
import json, os, re, sys, time, urllib.request, urllib.error
S = os.path.dirname(os.path.abspath(__file__)) + '/jev-corpus'
KEY = os.environ['TYPESAFE_API_KEY']
Q = {
  "needs_action": {"type": "noul",
    "instructions": "Does `letter` ask the recipient session to do something or to answer something?",
    "criteria": {"true": "It contains a task, a request, or a question the recipient is expected to act on or answer",
                 "false": "It only informs, confirms, reports results, or acknowledges; nothing is asked of the recipient"}},
  "awaits_reply": {"type": "noul",
    "instructions": "Does the sender of `letter` expect a reply letter from the recipient?",
    "criteria": {"true": "The sender asks a question, requests confirmation, or explicitly says a reply is wanted",
                 "false": "The sender says no reply is needed, or the letter is a pure report, notice or acknowledgment"}},
  "time_sensitive": {"type": "noul",
    "instructions": "Does `letter` say the matter is blocking the sender now or must be handled promptly?",
    "criteria": {"true": "It states a deadline, that something is blocked or waiting on the recipient, or asks for prompt action",
                 "false": "No urgency is expressed; it can wait for the recipient's next convenient moment"}},
  "kind": {"type": "choice",
    "instructions": {"question": "What kind of letter is `letter`, judged by what it asks of the recipient?",
      "precedence": "A letter often reports results AND asks something at the end. Judge by the ask, not by the length: if any part asks the recipient a question or waits for a decision, it is 'question'; if any part asks the recipient to perform an action, it is 'request'. Only a letter that asks nothing of the recipient can be 'report', 'info' or 'ack'."},
    "criteria": {"question": "somewhere in the letter the recipient is asked a question or asked to decide/choose/rule on something, and the sender waits for that answer (even if most of the letter reports results)",
                 "request": "somewhere in the letter the recipient is asked to perform an action or task (fix, update, send, run, check), even if most of the letter reports results; no decision is asked",
                 "report": "answers an earlier question or reports results, findings or completed work, and asks nothing of the recipient",
                 "info": "shares information, a notice or a release announcement; asks nothing of the recipient and expects no reply",
                 "ack": "a short acknowledgment, thanks or confirmation with no new content"}},
}
def parse(path):
    raw = open(path, errors='replace').read()
    head, _, body = raw.partition('\n\n')
    h = dict(re.findall(r'^([A-Za-z-]+): (.*)$', head, re.M))
    return h, body
def call(state):
    req = urllib.request.Request('https://api.typesafe.ai/v1/systemone',
        data=json.dumps({"model": "jev-latest", "state": state, "questions": Q}).encode(),
        headers={'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json'})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r: return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (429, 529): time.sleep(2 ** attempt); continue
            raise
    raise RuntimeError('gave up')
total_in = total_out = 0; t0 = time.time()
for f in sorted(os.listdir(S)):
    if not f.endswith('.letter'): continue
    out = S + '/' + f.replace('.letter', '.jev2.json')
    if os.path.exists(out): continue
    h, body = parse(S + '/' + f)
    state = {"letter": {"from": h.get('From'), "to": h.get('To'), "subject": h.get('Subject', ''),
             "is_reply": 'In-Reply-To' in h, "body": body[:3000]}}
    t1 = time.time(); res = call(state); dt = time.time() - t1
    res['_latency_s'] = round(dt, 2); json.dump(res, open(out, 'w'), ensure_ascii=False, indent=1)
    u = res['usage']; total_in += u['input_tokens']; total_out += u['output_tokens']
    a = res['answers']
    print(f"{f[:2]} {dt:4.1f}s kind={a['kind']['choice']:<8} conf={a['kind']['confidence']:.2f} action={a['needs_action']['noul']:.2f} reply={a['awaits_reply']['noul']:.2f} urgent={a['time_sensitive']['noul']:.2f}")
print(f"total {time.time()-t0:.0f}s tokens in={total_in} out={total_out}")

#!/bin/bash
# Silent Claude Code status-line hook: saves only the rate_limits block for UsageBar. Prints nothing.
exec >/dev/null 2>&1
out="$HOME/Library/Application Support/UsageBar/claude.json"
/usr/bin/python3 -c '
import json,sys,os,tempfile
tmp = None
try:
    rl=json.load(sys.stdin).get("rate_limits")
    if isinstance(rl, dict) and rl:
        p=sys.argv[1]
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir=os.path.dirname(p),
                                         prefix="claude-", suffix=".tmp", delete=False) as f:
            tmp=f.name
            json.dump(rl,f)
        os.replace(tmp,p)
        tmp=None
except Exception: pass
finally:
    if tmp is not None:
        try: os.unlink(tmp)
        except OSError: pass
' "$out"
exit 0

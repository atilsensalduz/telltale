#!/usr/bin/env python3
"""Regenerate Tests/TelltaleCoreTests/Fixtures/rule_table.json from netwatch.py's diagnose().

Run from anywhere:  python3 TelltaleCore/Scripts/gen_rule_table.py
The Swift test `ruleTableMatchesPythonOracle` fails if Rules.classify disagrees with this table.
"""
import importlib.util
import itertools
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("netwatch", root / "netwatch.py")
nw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nw)

rows = []
for bits in itertools.product([1, 0], repeat=5):  # gateway, cloudflare, google, dns, https
    vals = [10.0 if b else None for b in bits]
    rows.append({"ok": "".join(map(str, bits)), "cause": nw.diagnose(vals)})

out = root / "TelltaleCore/Tests/TelltaleCoreTests/Fixtures/rule_table.json"
out.write_text(json.dumps(rows, indent=1) + "\n")
print(f"wrote {out} ({len(rows)} rows)")

#!/usr/bin/env python3
# STAP 0 van de cache-workflow: inspecteert MSAL-cache / token bestanden op STRUCTUUR +
# token-vervaldatum, ZONDER secret-waarden te tonen. Zo zie je of een bestaande cache
# volstaat voordat je het keyring-pad (make_cache_available.sh) inslaat.
#   python3 inspect_cache.py <repo>/token-cache/msal-cache.json <repo>/token-cache/token.json
# Bruikbaar voor de headless shim = MSAL-contract met een (niet-verlopen-te-verversen) RefreshToken.
import json, base64, sys, time

def report_inner(inner):
    for sec in ("AccessToken","RefreshToken","Account","IdToken","AppMetadata"):
        entries = inner.get(sec) or {}
        n = len(entries) if isinstance(entries, dict) else 0
        print(f"  [{sec}] {n} entries")
        if isinstance(entries, dict):
            for k, fields in entries.items():
                if sec == "AccessToken":
                    exp = fields.get("expires_on")
                    try:
                        exp = int(exp); left = exp - int(time.time())
                        dt = time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime(exp))
                        print(f"      AT expires_on={exp} ({dt}) -> {'GELDIG' if left>0 else 'VERLOPEN'} ({left}s)")
                    except Exception:
                        print(f"      AT expires_on={exp!r}")
                elif sec == "Account":
                    print(f"      username={fields.get('username')!r} realm={fields.get('realm')!r} home={fields.get('home_account_id')!r}")

def show(path):
    print(f"\n===== {path} =====")
    try:
        raw = open(path, encoding="utf-8").read()
    except Exception as e:
        print(f"  (lezen faalde: {e})"); return
    try:
        obj = json.loads(raw)
    except Exception as e:
        print(f"  (geen JSON: {e})"); return
    # Plat OAuth-token-antwoord (token.json) -> geen MSAL-contract; toon refresh_token-status
    if isinstance(obj, dict) and ("refresh_token" in obj or "access_token" in obj):
        print("  type: PLAT OAuth-token-antwoord (NIET het MSAL-cache-contract voor connectAadProfile)")
        exp = obj.get("expires_on")
        try:
            exp = int(exp); print(f"  access_token expires {time.strftime('%Y-%m-%d %H:%M:%SZ',time.gmtime(exp))} -> {'GELDIG' if exp>time.time() else 'VERLOPEN'}")
        except Exception: pass
        print(f"  has refresh_token: {bool(obj.get('refresh_token'))} (len {len(obj.get('refresh_token',''))})")
        print(f"  resource/client_id: {obj.get('resource')} / {obj.get('client_id')}")
        return
    # MSAL-contract: {"<part>": "base64(inner)"} of direct de secties
    if isinstance(obj, dict) and obj and all(isinstance(v, str) for v in obj.values()):
        print("  type: MSAL-cache-contract (base64-partities)")
        for part, b64 in obj.items():
            try:
                report_inner(json.loads(base64.b64decode(b64).decode("utf-8")))
            except Exception as e:
                print(f"  partitie {part!r}: decode faalde ({e})")
    else:
        print("  type: MSAL-cache (platte secties)")
        report_inner(obj)

if len(sys.argv) < 2:
    print("gebruik: python3 inspect_cache.py <cache.json> [meer...]"); sys.exit(1)
for p in sys.argv[1:]:
    show(p)

#!/usr/bin/python3
# Unlockt ALLE vergrendelde keyring-collections (incl. "Default keyring") via de gcr
# GUI-prompt (WSLg toont een dialoog), extraheert het AzVPN MSAL-item en schrijft
# azvpn_securestorage.bin + msalcache.json.  Draai met /usr/bin/python3 (heeft secretstorage).
# Output-dir: argv[1] (default: map van dit script).
import secretstorage, sys, json, os
D = (sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))).rstrip("/") + "/"
conn = secretstorage.dbus_init()

colls = list(secretstorage.get_all_collections(conn))
for coll in colls:
    try:
        if coll.is_locked():
            print(f"unlock: '{coll.get_label()}' -> GUI-prompt verschijnt in WSLg...", file=sys.stderr)
            coll.unlock()
            print(f"  '{coll.get_label()}' locked nu = {coll.is_locked()}", file=sys.stderr)
    except Exception as e:
        print(f"  (unlock faalde voor '{coll.get_label()}': {e})", file=sys.stderr)

secret = None
for coll in colls:
    if coll.is_locked():
        continue
    try:
        for item in coll.get_all_items():
            if item.get_attributes().get('account') == 'microsoft-azurevpnclient.secureStorage':
                secret = item.get_secret()
                print(f"item gevonden in '{coll.get_label()}'", file=sys.stderr)
                break
    except Exception as e:
        print(f"  (items niet leesbaar in '{coll.get_label()}': {e})", file=sys.stderr)
    if secret is not None:
        break

if secret is None:
    print("FAIL: AzVPN MSAL-item niet gevonden (keyring nog locked of verkeerd wachtwoord)", file=sys.stderr)
    sys.exit(2)

with open(D + "azvpn_securestorage.bin", "wb") as f:
    f.write(secret)
blob = json.loads(secret.decode("utf-8"))
msal = blob["AzureVpnClient_AzVPNClientMsalcache_"]
with open(D + "msalcache.json", "w", encoding="utf-8") as f:
    f.write(msal)
print(f"OK: msalcache.json = {len(msal)} bytes -> {D}msalcache.json", file=sys.stderr)

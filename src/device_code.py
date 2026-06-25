#!/usr/bin/env python3
"""Token cache manager voor Azure VPN.
Gebruik: device_code.py <tenant_id> <audience> <cache_path>

Gedrag:
  1. Bestaande cache aanwezig?
     a. Al 2-niveau formaat met geldig token → exit 0 (geen flow nodig)
     b. Python MSAL formaat met geldig token → converteren naar 2-niveau, exit 0
     c. Token verlopen of formaat onbekend → device code flow starten
  2. Cache ontbreekt → device code flow starten

2-niveau formaat (zie docs/re/cache-format.md):
  {"": "<base64(msalJson)>", "<homeId>": "<base64(msalJson)>"}
"""
import sys, os, json, time, base64

try:
    import msal
except ImportError:
    sys.exit("Error: msal not installed — run `pip3 install msal`")

# De library zoekt cache-entries op met c632b3df als client_id in de sleutel.
MSAL_CACHE_CLIENT = "c632b3df-fb67-4d84-bdcf-b95ad541b5c8"
MARGIN_SECS = 60  # token als verlopen beschouwen 60s voor expiry


def build_two_level(access_token, expires_in, ext_expires_in, audience, realm,
                    home_id, local_oid, upn, refresh_token=None):
    """
    realm         = resource/token tenant (bijv. OOM-tenant voor guest-users)
    home_id       = "{oid_in_home_tenant}.{home_tenant_id}"  — altijd home-context
    local_oid     = OID in de resource tenant (= local_account_id in Python MSAL)
    refresh_token = optionele RT om op te slaan (voor stille verlenging)

    Noot: libLinuxCore.so gebruikt 'username' (niet 'preferred_username') als JSON-veld.
    AppMetadata met c632b3df is vereist zodat GetAccounts() accounts teruggeeft.
    """
    now   = int(time.time())
    scope = f"{audience}/.default"

    at_key  = (f"{home_id}-login.microsoftonline.com-accesstoken"
               f"-{MSAL_CACHE_CLIENT}-{realm}-{scope}")
    rt_key  = (f"{home_id}-login.microsoftonline.com-refreshtoken"
               f"-{MSAL_CACHE_CLIENT}")
    acc_key = f"{home_id}-login.microsoftonline.com-{realm}"

    refresh_token_section = {}
    if refresh_token:
        refresh_token_section[rt_key] = {
            "home_account_id": home_id,
            "environment":     "login.microsoftonline.com",
            "credential_type": "RefreshToken",
            "client_id":       MSAL_CACHE_CLIENT,
            "secret":          refresh_token,
        }

    inner = {
        "AccessToken": {
            at_key: {
                "home_account_id":     home_id,
                "environment":         "login.microsoftonline.com",
                "client_id":           MSAL_CACHE_CLIENT,
                "target":              scope,
                "realm":               realm,
                "credential_type":     "AccessToken",
                "token_type":          "Bearer",
                "secret":              access_token,
                "cached_at":           str(now),
                "expires_on":          str(now + expires_in),
                "extended_expires_on": str(now + ext_expires_in),
            }
        },
        "RefreshToken": refresh_token_section,
        "IdToken":      {},
        "Account": {
            acc_key: {
                "home_account_id": home_id,
                "environment":     "login.microsoftonline.com",
                "realm":           realm,
                "local_account_id": local_oid,
                "authority_type":  "MSSTS",
                # libLinuxCore.so gebruikt 'username', niet 'preferred_username'
                "username":        upn,
            }
        },
        "AppMetadata": {
            f"appmetadata-login.microsoftonline.com-{MSAL_CACHE_CLIENT}": {
                "client_id":   MSAL_CACHE_CLIENT,
                "environment": "login.microsoftonline.com",
            }
        },
    }

    b64 = base64.b64encode(json.dumps(inner, separators=(',', ':')).encode()).decode()
    return {"": b64, home_id: b64}


def _extract_msal_fields(cache_dict):
    """
    Extraheer home_id, local_oid, realm, upn uit een Python MSAL cache dict.
    Werkt zowel voor directe gebruikers (home_id = oid.tenant) als guest-users.
    """
    home_id = realm = ""
    local_oid = upn = ""
    for at_v in cache_dict.get("AccessToken", {}).values():
        home_id = at_v.get("home_account_id", "")
        realm   = at_v.get("realm", "")
        break
    for acc_v in cache_dict.get("Account", {}).values():
        if not home_id or acc_v.get("home_account_id") == home_id:
            local_oid = acc_v.get("local_account_id", "")
            upn       = acc_v.get("preferred_username", "") or acc_v.get("username", "")
            if not home_id:
                home_id = acc_v.get("home_account_id", "")
            break
    return home_id, local_oid, realm, upn


def try_refresh_python_msal(data, audience, tenant_id, cache_path):
    """
    Gebruik de refresh token in een Python MSAL cache om een nieuw access token te halen.
    Slaat het resultaat op in 2-niveau formaat.
    """
    # Extraheer velden uit originele cache (voor het geval de refresh geen id_token geeft)
    home_id_orig, local_oid_orig, realm_orig, upn_orig = _extract_msal_fields(data)

    client_id = None
    for at_val in data.get("AccessToken", {}).values():
        client_id = at_val.get("client_id")
        break
    if not client_id:
        client_id = audience
    used_tenant = realm_orig or tenant_id

    token_cache = msal.SerializableTokenCache()
    token_cache.deserialize(json.dumps(data))

    app = msal.PublicClientApplication(
        client_id,
        authority=f"https://login.microsoftonline.com/{used_tenant}",
        token_cache=token_cache,
    )
    accounts = app.get_accounts()
    if not accounts:
        print("No accounts in cache for refresh.", file=sys.stderr)
        return False

    scope = f"{audience}/.default"
    result = app.acquire_token_silent([scope], account=accounts[0])
    if not result or "access_token" not in result:
        err = result.get("error_description", "no access_token") if result else "no result"
        print(f"Refresh failed: {err}", file=sys.stderr)
        return False

    # Na de refresh: haal bijgewerkte home_id/local_oid en refresh_token uit de token_cache
    refreshed = json.loads(token_cache.serialize())
    home_id, local_oid, realm, upn = _extract_msal_fields(refreshed)
    if not home_id:
        home_id = home_id_orig
    if not local_oid:
        local_oid = local_oid_orig
    if not realm:
        realm = used_tenant
    if not upn:
        upn = upn_orig

    # Kopieer refresh token uit Python MSAL cache voor toekomstige stille verlengingen
    rt = None
    for rt_v in refreshed.get("RefreshToken", {}).values():
        rt = rt_v.get("secret")
        break

    expires_in  = result.get("expires_in", 3600)
    ext_expires = result.get("ext_expires_in", expires_in)

    outer = build_two_level(
        access_token   = result["access_token"],
        expires_in     = expires_in,
        ext_expires_in = ext_expires,
        audience       = audience,
        realm          = realm,
        home_id        = home_id,
        local_oid      = local_oid,
        upn            = upn,
        refresh_token  = rt,
    )
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(outer, f, separators=(',', ':'))

    exp = time.strftime('%H:%M', time.localtime(int(time.time()) + expires_in))
    print(f"Token refreshed via refresh token and saved (expires {exp}).")
    return True


def try_migrate(cache_path, audience, tenant_id):
    """
    Lees bestaande cache, detecteer formaat en converteer indien nodig.
    Retourneert True als er een geldig token beschikbaar is (na eventuele conversie).
    """
    try:
        with open(cache_path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"Warning: could not read cache: {e}", file=sys.stderr)
        return False

    now = int(time.time())

    # ── 2-niveau formaat: waarden zijn strings (base64) ──────────────────────
    if data and all(isinstance(v, str) for v in data.values()):
        inner_json = None
        for b64val in data.values():
            try:
                inner_json = json.loads(base64.b64decode(b64val))
                break
            except Exception:
                continue

        if inner_json:
            for at_val in inner_json.get("AccessToken", {}).values():
                if int(at_val.get("expires_on", 0)) > now + MARGIN_SECS:
                    exp = time.strftime('%H:%M', time.localtime(int(at_val["expires_on"])))
                    print(f"Cache is valid (2-level format, expires {exp}).")
                    return True

        print("Cache is in 2-level format but token has expired — trying refresh...")
        # Gebruik de gedecoded inner JSON (Python MSAL flat formaat) voor refresh
        if inner_json and inner_json.get("RefreshToken"):
            return try_refresh_python_msal(inner_json, audience, tenant_id, cache_path)
        return False

    # ── Python MSAL formaat: waarden zijn objecten ────────────────────────────
    if "AccessToken" in data:
        for at_val in data["AccessToken"].values():
            expires_on = int(at_val.get("expires_on", 0))
            if expires_on <= now + MARGIN_SECS:
                continue
            access_token = at_val.get("secret", "")
            if not access_token:
                continue

            # Gebruik de correcte home_id en local_oid uit de cache (werkt ook voor guest-users)
            home_id, local_oid, realm, upn = _extract_msal_fields(data)
            if not realm:
                realm = tenant_id

            ext_exp = int(at_val.get("extended_expires_on", expires_on))
            outer = build_two_level(
                access_token   = access_token,
                expires_in     = expires_on - now,
                ext_expires_in = ext_exp - now,
                audience       = audience,
                realm          = realm,
                home_id        = home_id,
                local_oid      = local_oid,
                upn            = upn,
            )
            with open(cache_path, "w", encoding="utf-8") as f:
                json.dump(outer, f, separators=(',', ':'))

            exp = time.strftime('%H:%M', time.localtime(expires_on))
            print(f"Converted Python MSAL cache to 2-level format (expires {exp}).")
            return True

        print("Cache is in Python MSAL format but token has expired — trying refresh token...")
        return try_refresh_python_msal(data, audience, tenant_id, cache_path)

    print("Cache format not recognised.")
    return False


def run_device_code(tenant_id, audience, cache_path):
    scope     = f"{audience}/.default"
    authority = f"https://login.microsoftonline.com/{tenant_id}"

    token_cache = msal.SerializableTokenCache()
    app  = msal.PublicClientApplication(audience, authority=authority, token_cache=token_cache)
    flow = app.initiate_device_flow(scopes=[scope])
    if "user_code" not in flow:
        sys.exit(f"Device flow failed: {flow}")

    print()
    print(flow["message"])
    print()

    result = app.acquire_token_by_device_flow(flow)
    if "error" in result:
        sys.exit(f"Auth failed: {result.get('error_description', result['error'])}")

    # Extraheer home_id/local_oid en refresh_token uit de Python MSAL cache
    cached    = json.loads(token_cache.serialize())
    home_id, local_oid, realm, upn = _extract_msal_fields(cached)
    if not realm:
        realm = tenant_id
    if not upn:
        upn = result.get("id_token_claims", {}).get("preferred_username", "")

    rt = None
    for rt_v in cached.get("RefreshToken", {}).values():
        rt = rt_v.get("secret")
        break

    expires_in  = result.get("expires_in", 3600)
    ext_expires = result.get("ext_expires_in", 86400)

    outer = build_two_level(
        access_token   = result["access_token"],
        expires_in     = expires_in,
        ext_expires_in = ext_expires,
        audience       = audience,
        realm          = realm,
        home_id        = home_id,
        local_oid      = local_oid,
        upn            = upn,
        refresh_token  = rt,
    )

    os.makedirs(os.path.dirname(os.path.abspath(cache_path)), exist_ok=True)
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(outer, f, separators=(',', ':'))

    now = int(time.time())
    print(f"Token saved: {cache_path}")
    print(f"Expires:     {time.strftime('%Y-%m-%d %H:%M', time.localtime(now + expires_in))}")


def main():
    if len(sys.argv) < 4:
        sys.exit("Usage: device_code.py <tenant_id> <audience> <cache_path>")

    tenant_id, audience, cache_path = sys.argv[1], sys.argv[2], sys.argv[3]

    if os.path.exists(cache_path):
        if try_migrate(cache_path, audience, tenant_id):
            return  # token geldig, geen device code nodig

    run_device_code(tenant_id, audience, cache_path)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Extract the raw AAD access token from a 2-level MSAL cache (see docs/re/cache-format.md).
Usage: extract_token.py <cache_path>
Prints only the token to stdout, so callers can capture it directly into a variable."""
import base64
import json
import sys


def decode_inner(value):
    try:
        return json.loads(base64.b64decode(value).decode("utf-8"))
    except Exception:
        return None


def extract_secret_from_inner(inner):
    access = inner.get("AccessToken")
    if not isinstance(access, dict):
        return None
    for entry in access.values():
        if isinstance(entry, dict):
            secret = entry.get("secret")
            if isinstance(secret, str) and secret:
                return secret
    return None


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: extract_token.py <cache_path>\n")
        sys.exit(2)

    cache_path = sys.argv[1]

    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            outer = json.load(f)
    except Exception:
        sys.stderr.write("Failed to read or parse cache file\n")
        sys.exit(1)

    if not isinstance(outer, dict):
        sys.stderr.write("Invalid cache format\n")
        sys.exit(1)

    for value in outer.values():
        if not isinstance(value, str):
            continue
        inner = decode_inner(value)
        if not isinstance(inner, dict):
            continue
        secret = extract_secret_from_inner(inner)
        if secret:
            sys.stdout.write(secret)
            return

    sys.stderr.write("No AccessToken with non-empty secret found\n")
    sys.exit(1)


if __name__ == "__main__":
    main()

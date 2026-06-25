#!/usr/bin/env bash
# Downloadt de DigiCert Global Root G2 CA en schrijft src/dr.pem.
# Haal opnieuw op als het cert verlopen of verdacht is.
# Verifieer: CN moet "DigiCert Global Root G2" zijn, geldig t/m 2038.
#
# Gebruik:
#   bash src/fetch-dr-pem.sh                  # schrijft src/dr.pem
#   bash src/fetch-dr-pem.sh /pad/naar/dr.pem # alternatief uitvoerpad
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$SCRIPT_DIR/dr.pem}"

# DigiCert publiceert hun root-certs op een vaste URL
URL="https://cacerts.digicert.com/DigiCertGlobalRootG2.crt.pem"

echo "Downloaden van $URL..."
curl -fsSL "$URL" -o "$OUT"

# Verificatie: controleer Subject CN
CN=$(openssl x509 -in "$OUT" -noout -subject 2>/dev/null | grep -oP '(?<=CN\s?=\s?).*')
echo "Subject CN: $CN"
if [[ "$CN" != *"DigiCert Global Root G2"* ]]; then
    echo "FOUT: onverwacht CN — verwacht 'DigiCert Global Root G2', kreeg '$CN'"
    rm -f "$OUT"
    exit 1
fi

# Controleer geldigheid (niet verlopen)
EXPIRY=$(openssl x509 -in "$OUT" -noout -enddate 2>/dev/null | cut -d= -f2)
echo "Geldig tot: $EXPIRY"

echo "✓ dr.pem OK → $OUT"

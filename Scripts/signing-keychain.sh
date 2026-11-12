#!/bin/bash
# Makes the keychain that release.yml signs with, or removes it again.
#
#   signing-keychain.sh create   with P12 and P12_PASSWORD set
#   signing-keychain.sh delete
#
# The keychain is there only while something is signed, so that no other
# step, nor the packages it installs, can sign with it.
set -euo pipefail

keychain="$RUNNER_TEMP/signing.keychain-db"

case "${1:-}" in
create)
    password=$(uuidgen)
    certificate="$RUNNER_TEMP/certificate.p12"
    trap 'rm -f "$certificate"' EXIT
    echo "$P12" | base64 --decode > "$certificate"
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings -lut 3600 "$keychain"
    security unlock-keychain -p "$password" "$keychain"
    security import "$certificate" -k "$keychain" -P "$P12_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" > /dev/null
    security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
    ;;
delete)
    security delete-keychain "$keychain" 2> /dev/null || true
    ;;
*)
    echo "usage: $0 create|delete" >&2
    exit 64
    ;;
esac

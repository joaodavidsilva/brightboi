#!/bin/bash
# Checks that an app bundle is signed the way a notarized release must be:
# with a Developer ID Application certificate, and with a secure timestamp.
#
# Usage: Packaging/check-developer-id.sh <path-to-app>
#
# Exits 0 when both hold, non-zero otherwise, printing codesign's own
# diagnostic. Nothing here pipes codesign into grep: under `pipefail`, a
# `grep -q` that exits on its first match makes codesign die of SIGPIPE and
# the whole pipeline report failure, even for a correct signature.
set -euo pipefail

# Certificate OIDs rather than display strings: intermediate certificate
# marker for Developer ID Certification Authority, and leaf marker for a
# Developer ID Application certificate.
DEVELOPER_ID_REQ='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'

# Prints codesign's diagnostic and returns non-zero unless the bundle's
# signature satisfies the Developer ID requirement.
has_developer_id_signature() {
    local app="$1" out
    if ! out="$(codesign --verify --strict -R="$DEVELOPER_ID_REQ" "$app" 2>&1)"; then
        echo "$out" >&2
        return 1
    fi
}

# Notarization rejects a signature without a secure timestamp.
has_secure_timestamp() {
    local app="$1" details
    details="$(codesign -dvv "$app" 2>&1)"
    [[ "$details" == *"Timestamp="* ]]
}

check_developer_id() {
    local app="$1"
    if ! has_developer_id_signature "$app"; then
        echo "error: $app is not signed with a Developer ID Application certificate." >&2
        echo "Install one, or set CODESIGN_IDENTITY to select it, then re-run." >&2
        return 1
    fi
    if ! has_secure_timestamp "$app"; then
        echo "error: $app has no secure timestamp in its signature; notarization would reject it." >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $# -ne 1 ]]; then
        echo "usage: $0 <path-to-app>" >&2
        exit 2
    fi
    check_developer_id "$1"
fi

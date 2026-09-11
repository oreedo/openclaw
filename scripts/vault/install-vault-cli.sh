#!/usr/bin/env bash
set -euo pipefail

# Idempotent install of the HashiCorp Vault CLI from releases.hashicorp.com.
# Verifies the SHA256SUMS GPG signature against HashiCorp's release key
# (fingerprint pinned below) and the zip checksum before installing.
#
# Default version matches the server image (bitnami/vault:1.18.5).

VERSION="1.18.5"
DEST="/usr/local/bin"
ARCH="$(dpkg --print-architecture)"
KEY_URL="https://www.hashicorp.com/.well-known/pgp-key.txt"
KEY_FPR="C874011F0AB405110D02105534365D9472D7468F"

usage() {
  cat <<'EOF'
Usage:
  install-vault-cli.sh [options]

Options:
  --version <x.y.z>   Vault version to install (default: 1.18.5)
  --dest <dir>        install directory (default: /usr/local/bin)
  -h, --help          show help
EOF
}

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) VERSION="$2"; shift 2 ;;
      --dest) DEST="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done

  for c in curl gpg unzip sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done

  if [[ -x "$DEST/vault" ]] && "$DEST/vault" version 2>/dev/null | grep -q "^Vault v${VERSION} "; then
    log "Vault CLI v${VERSION} already installed at $DEST/vault"
    exit 0
  fi

  local tmp zip base
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: $tmp is local and gone when the EXIT trap fires
  trap "rm -rf '$tmp'" EXIT
  zip="vault_${VERSION}_linux_${ARCH}.zip"
  base="https://releases.hashicorp.com/vault/${VERSION}"

  log "Downloading $zip, SHA256SUMS and signature"
  curl -fsSLo "$tmp/$zip" "$base/$zip"
  curl -fsSLo "$tmp/SHA256SUMS" "$base/vault_${VERSION}_SHA256SUMS"
  curl -fsSLo "$tmp/SHA256SUMS.sig" "$base/vault_${VERSION}_SHA256SUMS.sig"
  curl -fsSLo "$tmp/hashicorp.asc" "$KEY_URL"

  log "Verifying GPG signature (isolated keyring, pinned fingerprint $KEY_FPR)"
  export GNUPGHOME="$tmp/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --import "$tmp/hashicorp.asc"
  # Pin the SIGNER, not just the key's presence: the key file could carry extra
  # keys. VALIDSIG's last field is the signing key's primary fingerprint.
  gpg --batch --status-fd 1 --verify "$tmp/SHA256SUMS.sig" "$tmp/SHA256SUMS" 2>/dev/null \
    | awk '$2 == "VALIDSIG" {print $NF}' | grep -qx "$KEY_FPR" \
    || die "SHA256SUMS is not validly signed by $KEY_FPR"

  log "Verifying checksum of $zip"
  (cd "$tmp" && grep " ${zip}\$" SHA256SUMS | sha256sum -c --quiet -) \
    || die "checksum mismatch for $zip"

  unzip -o -q "$tmp/$zip" -d "$tmp/bin"
  install -m 0755 "$tmp/bin/vault" "$DEST/vault"
  log "Installed: $("$DEST/vault" version)"
}

main "$@"

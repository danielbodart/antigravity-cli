#!/usr/bin/env bash
#
# Regenerate sources.json from Google's Antigravity CLI release feed.
#
# Be clear about what this does and does not establish. Google publishes the
# CLI with no PGP signature, no detached signature and no signed index. The
# feed is a small JSON document per platform, {version, url, sha512}, served
# from a Cloud Run service, and the tarball it points at is served from
# storage.googleapis.com. Both come from Google over TLS, and there is nothing
# else to anchor either one to. So the trust chain here is:
#
#   TLS to Google's feed  ->  the feed's sha512  ->  TLS to Google's bucket
#
# which is weaker than claude-desktop's chain to a pinned PGP key. What this
# script adds is a cross-check rather than a signature:
#
#   * the URL must be on storage.googleapis.com, under the CLI's own path;
#   * the version in the URL must be the version in the feed;
#   * both architectures must agree on the version and the build;
#   * each tarball is downloaded here and hashed, and the sha512 the feed
#     claims must match the bytes. A feed and a bucket that disagree, a
#     truncated download, or a tampered mirror all fail here, not in Nix.
#
# Only then is the hash written down, as the SRI form Nix checks at build time.
# A compromise of Google's own publishing pipeline is out of reach of any of
# this.
#
set -euo pipefail

readonly FEED="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests"
readonly URL_PREFIX="https://storage.googleapis.com/antigravity-public/antigravity-cli/"

# Feed platform -> Nix system -> directory and file name inside the version's
# path in the bucket. Google's own names, not ours: arm64 lives in "linux-arm".
readonly PLATFORMS=("linux_amd64:x86_64-linux:linux-x64/cli_linux_x64.tar.gz" "linux_arm64:aarch64-linux:linux-arm/cli_linux_arm64.tar.gz")

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SOURCES_JSON="$ROOT/sources.json"

log() { printf '\033[0;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  for tool in curl jq nix sha512sum tar; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]} (try: nix develop)"
}

fetch() {
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --max-time 120 "$1"
}

main() {
  local check_only=false force=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --force) force=true; shift ;;
      --help)
        cat <<'USAGE'
Usage: scripts/update.sh [--check] [--force]

Rewrites sources.json from Google's Antigravity CLI release feed, after
downloading each tarball to confirm it matches the sha512 the feed gives.

  --check   Report whether an update is available and exit non-zero if one
            is, without downloading or writing anything.
  --force   Download, verify and rewrite sources.json even when the pinned
            version is already the newest one, so that its contents can be
            compared against the feed.
USAGE
        exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  require_tools

  local workdir
  workdir="$(mktemp -d)"
  # Expanded now, not at trap time: $workdir is a local that is out of scope
  # by the time the EXIT trap runs.
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" EXIT

  local -A url_of sha512_of version_of build_of
  local entry platform system path manifest

  for entry in "${PLATFORMS[@]}"; do
    IFS=: read -r platform system path <<<"$entry"

    log "fetching $FEED/$platform.json"
    manifest="$(fetch "$FEED/$platform.json")"

    local version url sha512
    version="$(jq -er '.version | strings' <<<"$manifest")" || die "$platform: feed has no version"
    url="$(jq -er '.url | strings' <<<"$manifest")" || die "$platform: feed has no url"
    sha512="$(jq -er '.sha512 | strings' <<<"$manifest")" || die "$platform: feed has no sha512"

    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
      die "$platform: version '$version' is not major.minor.patch"
    [[ "$sha512" =~ ^[0-9a-f]{128}$ ]] ||
      die "$platform: sha512 is not 128 lowercase hex digits"

    # The URL has to be Google's bucket, under the CLI's path, at
    # <version>-<build>/<platform dir>/<file>. Matching the whole string
    # rather than the host alone is what stops a feed that was pointed
    # somewhere else, or a path with ".." in it, getting through.
    [[ "$url" == "$URL_PREFIX"* ]] || die "$platform: url is not under $URL_PREFIX: $url"
    local rest="${url#"$URL_PREFIX"}"
    [[ "$rest" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)/(.+)$ ]] ||
      die "$platform: url path is not <version>-<build>/...: $url"
    [ "${BASH_REMATCH[1]}" = "$version" ] ||
      die "$platform: url is for ${BASH_REMATCH[1]} but the feed says $version"
    [ "${BASH_REMATCH[3]}" = "$path" ] ||
      die "$platform: url ends in ${BASH_REMATCH[3]}, expected $path"

    version_of[$system]="$version"
    build_of[$system]="${BASH_REMATCH[2]}"
    url_of[$system]="$url"
    sha512_of[$system]="$sha512"
    log "$platform: $version, build ${build_of[$system]}"
  done

  # One version attribute covers both architectures, so a release that is
  # only half-published is not one we can pin. The build has to agree too: it
  # is part of the URL, so two builds of the same version would be two
  # different releases.
  [ "${version_of[x86_64-linux]}" = "${version_of[aarch64-linux]}" ] ||
    die "architectures disagree on the version: ${version_of[x86_64-linux]} and ${version_of[aarch64-linux]}"
  [ "${build_of[x86_64-linux]}" = "${build_of[aarch64-linux]}" ] ||
    die "architectures disagree on the build: ${build_of[x86_64-linux]} and ${build_of[aarch64-linux]}"

  local latest_version="${version_of[x86_64-linux]}" latest_build="${build_of[x86_64-linux]}"
  local current_version current_build
  current_version="$(jq -r '.version' "$SOURCES_JSON" 2>/dev/null || echo none)"
  current_build="$(jq -r '.build' "$SOURCES_JSON" 2>/dev/null || echo none)"
  log "current: $current_version ($current_build), latest: $latest_version ($latest_build)"

  if [ "$current_version" = "$latest_version" ] && [ "$current_build" = "$latest_build" ] && [ "$force" = false ]; then
    log "already up to date"
    exit 0
  fi

  if [ "$check_only" = true ]; then
    log "update available: $current_version -> $latest_version"
    exit 1
  fi

  # The cross-check. Each tarball is about 100 MB, which is why this comes
  # after the up-to-date exit above and not before it.
  local json size actual sri
  json="$(jq -n --arg version "$latest_version" --arg build "$latest_build" \
    '{version: $version, build: $build, sources: {}}')"
  for entry in "${PLATFORMS[@]}"; do
    IFS=: read -r _ system _ <<<"$entry"

    log "downloading ${url_of[$system]}"
    fetch "${url_of[$system]}" >"$workdir/$system.tar.gz"

    actual="$(sha512sum "$workdir/$system.tar.gz" | cut -d' ' -f1)"
    [ "$actual" = "${sha512_of[$system]}" ] ||
      die "$system: the tarball hashes to $actual but the feed says ${sha512_of[$system]}"
    log "$system: sha512 matches the feed"

    # A tarball with anything else in it is not the one packaged here.
    [ "$(tar -tzf "$workdir/$system.tar.gz")" = "antigravity" ] ||
      die "$system: the tarball does not contain exactly one file, antigravity"

    size="$(stat -c %s "$workdir/$system.tar.gz")"
    sri="$(nix hash convert --hash-algo sha512 --to sri "$actual")"
    json="$(jq \
      --arg system "$system" \
      --arg url "${url_of[$system]}" \
      --arg hash "$sri" \
      --argjson size "$size" \
      '.sources[$system] = {url: $url, hash: $hash, size: $size}' \
      <<<"$json")"
    rm -f "$workdir/$system.tar.gz"
  done

  printf '%s\n' "$json" >"$SOURCES_JSON"
  log "wrote $SOURCES_JSON at $latest_version ($latest_build)"
}

main "$@"

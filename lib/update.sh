# shellcheck shell=bash
# Updates from GitHub releases. A release carries the tool as
# bazzite-sec-audit-VERSION.tar.gz, a SHA256SUMS file and SHA256SUMS.sig, an
# SSH signature (ssh-keygen -Y sign, namespace RELEASE_NAMESPACE) made by
# the release workflow with the key whose public half ships with the tool
# in release-signers. An update is installed only when that signature is
# good and the archive matches its checksum.

readonly RELEASE_NAMESPACE="bazzite-sec-audit-release"
readonly RELEASE_PRINCIPAL="release@bazzite-sec-audit"
# The trusted key: the copy that ships with this (running, root-owned when
# installed) tool. The tests point it elsewhere after sourcing.
RELEASE_SIGNERS="${SCRIPT_DIR}/release-signers"
RELEASE_API="https://api.github.com/repos/${APP_REPO}/releases/latest"
RELEASE_DOWNLOAD="https://github.com/${APP_REPO}/releases/download"

# _version_newer A B — version A is newer than B ("1.10.0" > "1.9.2").
_version_newer() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# update_latest_version — the latest release's version ("1.2.0").
update_latest_version() {
    _have curl || return 1
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 15 --max-filesize 1000000 \
        -H 'Accept: application/vnd.github+json' "$RELEASE_API" 2>/dev/null \
        | python3 -I -c '
import json, re, sys
try:
    t = json.load(sys.stdin).get("tag_name", "")
except ValueError:
    sys.exit(1)
t = t[1:] if t.startswith("v") else t
if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,3}", t):
    sys.exit(1)
print(t)'
}

# update_verify DIR VERSION — DIR holds the release files: the signature
# over SHA256SUMS is good, and the archive matches its line in it.
update_verify() {
    local d="$1" v="$2" tarball want got
    tarball="bazzite-sec-audit-${v}.tar.gz"
    [[ -s "$RELEASE_SIGNERS" ]] || return 1
    ssh-keygen -Y verify -f "$RELEASE_SIGNERS" -I "$RELEASE_PRINCIPAL" -n "$RELEASE_NAMESPACE" \
        -s "$d/SHA256SUMS.sig" < "$d/SHA256SUMS" > /dev/null 2>&1 || return 1
    # Exactly one line names the archive.
    want=$(awk -v f="$tarball" '$2 == f || $2 == "*" f { print $1 }' "$d/SHA256SUMS")
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || return 1
    got=$(sha256sum -- "$d/$tarball" | cut -d' ' -f1)
    [[ "$got" == "$want" ]]
}

# update_extract DIR VERSION — unpack the verified archive into DIR/src and
# print the tool's folder. Only plain files and folders inside the
# expected top folder are accepted.
update_extract() {
    local d="$1" v="$2"
    python3 -I - "$d/bazzite-sec-audit-${v}.tar.gz" "$d/src" "bazzite-sec-audit-${v}" << 'PY'
import os, sys, tarfile
archive, dest, top = sys.argv[1:4]
with tarfile.open(archive) as t:
    for m in t.getmembers():
        if not (m.name == top or m.name.startswith(top + "/")) or not (m.isfile() or m.isdir()) or ".." in m.name.split("/"):
            sys.exit(1)
    t.extractall(dest, filter="data")
p = os.path.join(dest, top)
if not all(os.path.exists(os.path.join(p, n)) for n in ("bazzite-sec-audit.sh", "lib", "checks", "ui", "release-signers")):
    sys.exit(1)
print(p)
PY
}

# update_run [quiet] — look for a newer release and, after asking, install
# it as the app. "quiet": say nothing when there is none (start-up check).
# Status 10 when an update was installed.
update_run() {
    local quiet="${1:-}" latest d f src
    [[ -n "$quiet" ]] && ui_busy_start "Looking for an update…"
    latest=$(update_latest_version) || latest=""
    [[ -n "$quiet" ]] && ui_busy_stop
    if [[ -z "$latest" ]]; then
        [[ -n "$quiet" ]] || ui_error "Could not reach GitHub to look for an update. Check the network and try again."
        return 1
    fi
    if ! _version_newer "$latest" "$SCRIPT_VERSION"; then
        [[ -n "$quiet" ]] || ui_msg "You have the latest version of Security Check (${SCRIPT_VERSION})."
        return 0
    fi
    ui_yesno "Security Check ${latest} is available (you have ${SCRIPT_VERSION}).

Update now? It is downloaded from GitHub (${APP_REPO}), its signature and
checksums are verified, and it is installed as the app in ${INSTALL_DIR}.
The new version is used the next time you start Security Check." "Update" "Not now" "y" || return 0
    d=$(mktemp -d "${RUN_TMP:-/tmp}/update.XXXXXX") || { ui_error "Could not create a private folder for the download."; return 1; }
    ui_busy_start "Downloading Security Check ${latest}…"
    for f in "bazzite-sec-audit-${latest}.tar.gz" SHA256SUMS SHA256SUMS.sig; do
        if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --max-filesize 50000000 \
               -o "$d/$f" "${RELEASE_DOWNLOAD}/v${latest}/${f}" 2>>"${RUN_LOG:-/dev/null}"; then
            ui_busy_stop
            rm -rf -- "$d"
            ui_error "Could not download ${f} of release ${latest}. Nothing was changed."
            return 1
        fi
    done
    ui_busy_stop
    if ! update_verify "$d" "$latest"; then
        log "update ${latest}: verification failed"
        rm -rf -- "$d"
        ui_error "The download of Security Check ${latest} did not pass verification (signature or checksum). Nothing was installed."
        return 1
    fi
    if ! src=$(update_extract "$d" "$latest"); then
        rm -rf -- "$d"
        ui_error "The release archive of Security Check ${latest} does not look right. Nothing was installed."
        return 1
    fi
    _install_app_files "$src" || { rm -rf -- "$d"; return 1; }
    rm -rf -- "$d"
    log "updated to ${latest}"
    print_status "OK" "Security Check ${latest} installed"
    ui_msg "Security Check ${latest} is installed. It is used the next time you start Security Check."
    # 10: installed (the start-up check then stops, so this run does not
    # carry on as half old, half new).
    return 10
}

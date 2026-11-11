#!/bin/sh
# Oatcake installer: downloads the latest release, checks it, puts it in Applications and opens it.
# Run it again any time to reinstall or upgrade; installed copies also update themselves.
#
#   curl -fsSL https://raw.githubusercontent.com/a8cteam51/oatcake/trunk/install.sh | sh
#
# Oatcake isn't notarised. Files curl downloads get no quarantine flag, so macOS doesn't block the
# app the way it blocks a downloaded zip; the checks below stand in for that.
#
# Optional environment:
#   OATCAKE_INSTALL_DIR   folder for Oatcake.app. Default: wherever it's installed already,
#                         else /Applications, else ~/Applications
#   OATCAKE_FEED          another latest.json, for trying a release before it's published
#                         (the zip is fetched from beside it)
#   OATCAKE_REINSTALL=1   reinstall even when this version is already there
#
# Checks: the zip's size and SHA-256 against the release's latest.json, that the zip holds just
# Oatcake.app of that version, validly signed with a certificate (so it can update itself), and that
# this Mac can run it. latest.json's own signature is checked by Oatcake's updater; this first
# install trusts GitHub over HTTPS. Adapted from Loominate's installer (github.com/a8cteam51/loominate).
#
# Everything is inside main(), so a download cut off halfway runs nothing.
main() {
    set -eu
    REPO="a8cteam51/oatcake"
    BUNDLE_ID="local.oatcake"
    FEED="${OATCAKE_FEED:-https://github.com/$REPO/releases/latest/download/latest.json}"

    say() { printf '%s\n' "$*"; }
    die() { printf 'Oatcake installer: %s\n' "$*" >&2; exit 1; }
    plist() { /usr/bin/plutil -extract "$2" raw -o - -- "$1/Contents/Info.plist" 2>/dev/null; }
    json() { /usr/bin/plutil -extract "$2" raw -o - -- "$1" 2>/dev/null; }
    # True when dotted version $1 is at least $2 (major.minor).
    at_least() {
        awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); exit !((x[1] + 0 > y[1] + 0) || (x[1] + 0 == y[1] + 0 && x[2] + 0 >= y[2] + 0)) }'
    }

    [ "$(id -u)" -ne 0 ] || die "don't run this with sudo; install as the person who will use Oatcake."
    [ "$(uname -s)" = "Darwin" ] || die "Oatcake is a Mac app."
    [ "$(uname -m)" = "arm64" ] || die "Oatcake needs a Mac with Apple silicon."
    MACOS="$(sw_vers -productVersion)"
    command -v curl >/dev/null || die "curl is missing."

    TMP="$(mktemp -d "${TMPDIR:-/tmp}/oatcake-install.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT INT TERM

    say "Checking the latest Oatcake release..."
    HTTP="$(curl -sSL -o "$TMP/latest.json" -w '%{http_code}' "$FEED" || true)"
    case "$HTTP" in
        200) ;;
        404) die "no release is available to install yet ($FEED)." ;;
        *) die "couldn't fetch the release information (HTTP ${HTTP:-?} from $FEED)." ;;
    esac
    json "$TMP/latest.json" payload | /usr/bin/base64 -d > "$TMP/payload.json" 2>/dev/null \
        || die "the release information isn't in the expected format."
    VERSION="$(json "$TMP/payload.json" version)"
    MIN_OS="$(json "$TMP/payload.json" minimumSystemVersion)"
    ZIP_NAME="$(json "$TMP/payload.json" zip.name)"
    ZIP_URL="$(json "$TMP/payload.json" zip.url)"
    ZIP_SHA="$(json "$TMP/payload.json" zip.sha256)"
    ZIP_SIZE="$(json "$TMP/payload.json" zip.size)"
    [ "$(json "$TMP/payload.json" bundleID)" = "$BUNDLE_ID" ] || die "the release information describes a different app."
    [ -n "$VERSION" ] && [ -n "$MIN_OS" ] && [ -n "$ZIP_NAME" ] && [ -n "$ZIP_SHA" ] && [ -n "$ZIP_SIZE" ] \
        || die "the release information is incomplete."
    case "$ZIP_NAME" in */* | *' '* | '') die "the release names an unexpected file." ;; esac
    if [ -n "${OATCAKE_FEED:-}" ]; then
        ZIP_URL="${FEED%/*}/$ZIP_NAME"
    fi
    at_least "$MACOS" "$MIN_OS" || die "Oatcake $VERSION needs macOS $MIN_OS or later; this Mac has $MACOS."

    if [ -n "${OATCAKE_INSTALL_DIR:-}" ]; then
        DEST_DIR="$OATCAKE_INSTALL_DIR"
    elif [ -d /Applications/Oatcake.app ]; then
        DEST_DIR=/Applications
    elif [ -d "$HOME/Applications/Oatcake.app" ]; then
        DEST_DIR="$HOME/Applications"
    elif [ -w /Applications ]; then
        DEST_DIR=/Applications
    else
        DEST_DIR="$HOME/Applications"
    fi
    mkdir -p "$DEST_DIR" 2>/dev/null || die "can't create $DEST_DIR."
    [ -w "$DEST_DIR" ] || die "can't write to $DEST_DIR. Set OATCAKE_INSTALL_DIR to a folder you own."
    DEST="$DEST_DIR/Oatcake.app"

    if [ -d "$DEST" ]; then
        CURRENT="$(plist "$DEST" CFBundleShortVersionString || echo unknown)"
        if [ "$CURRENT" = "$VERSION" ] && [ "${OATCAKE_REINSTALL:-0}" != 1 ]; then
            say "Oatcake $VERSION is already installed in $DEST_DIR."
            /usr/bin/open "$DEST"
            exit 0
        fi
        say "Upgrading Oatcake $CURRENT to $VERSION in $DEST_DIR"
    else
        say "Installing Oatcake $VERSION into $DEST_DIR"
    fi

    say "Downloading $ZIP_NAME ($((ZIP_SIZE / 1000000)) MB)..."
    curl -fL -# -o "$TMP/$ZIP_NAME" "$ZIP_URL" || die "the download failed ($ZIP_URL)."
    ACTUAL_SIZE="$(/usr/bin/stat -f %z "$TMP/$ZIP_NAME")"
    [ "$ACTUAL_SIZE" = "$ZIP_SIZE" ] || die "the download is $ACTUAL_SIZE bytes, not the $ZIP_SIZE the release promised. Nothing was installed."
    ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$TMP/$ZIP_NAME" | cut -d' ' -f1)"
    [ "$ACTUAL_SHA" = "$ZIP_SHA" ] || die "the download's checksum doesn't match the release. Nothing was installed."

    # ditto keeps the code signatures intact; unzip can break them.
    mkdir "$TMP/unpacked"
    /usr/bin/ditto -x -k "$TMP/$ZIP_NAME" "$TMP/unpacked" || die "couldn't unpack the download."
    NEW="$TMP/unpacked/Oatcake.app"
    [ -d "$NEW" ] || die "the download doesn't contain Oatcake.app."
    [ "$(ls -A "$TMP/unpacked" | wc -l | tr -d ' ')" = 1 ] || die "the download contains more than Oatcake.app."
    /usr/bin/codesign --verify --deep --strict "$NEW" 2>/dev/null || die "the downloaded app's code signature is invalid. Nothing was installed."
    case "$(/usr/bin/codesign -d -r - "$NEW" 2>/dev/null)" in
        *"certificate leaf"*) ;;
        *) die "the downloaded app isn't signed with Oatcake's release certificate. Nothing was installed." ;;
    esac
    [ "$(plist "$NEW" CFBundleIdentifier)" = "$BUNDLE_ID" ] || die "the downloaded app isn't Oatcake."
    [ "$(plist "$NEW" CFBundleShortVersionString)" = "$VERSION" ] || die "the downloaded app isn't version $VERSION."
    # curl doesn't set the quarantine flag, but clear it in case the zip arrived another way.
    /usr/bin/xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true

    if /usr/bin/pgrep -xq oatcake-recorder; then
        die "Oatcake is recording a call. Stop the recording, then run the installer again."
    fi
    if /usr/bin/pgrep -xq Oatcake; then
        say "Quitting Oatcake..."
        /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        i=0
        while /usr/bin/pgrep -xq Oatcake && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
        /usr/bin/pgrep -xq Oatcake && die "Oatcake is still open. Quit it, then run the installer again."
    fi

    OLD=""
    if [ -d "$DEST" ]; then
        OLD="$DEST_DIR/.Oatcake-old-$$.app"
        mv "$DEST" "$OLD" || die "couldn't move the installed copy aside."
    fi
    if /usr/bin/ditto "$NEW" "$DEST" && /usr/bin/codesign --verify --deep --strict "$DEST" 2>/dev/null; then
        [ -z "$OLD" ] || rm -rf "$OLD"
    else
        rm -rf "$DEST"
        [ -z "$OLD" ] || mv "$OLD" "$DEST"
        die "installing into $DEST_DIR failed; the previous copy was put back."
    fi
    touch "$DEST"
    /usr/bin/open "$DEST"

    say ""
    say "Installed Oatcake $VERSION in $DEST_DIR."
    say "The first recording asks for microphone and system-audio permission for \"OatcakeRecorder\"; allow both."
    say "Summaries are written on this Mac. Oatcake downloads the model for them (2.5 to 5 GB) during your first call."
    say "Oatcake checks for updates itself from now on (Settings > Updates)."
}

main "$@"

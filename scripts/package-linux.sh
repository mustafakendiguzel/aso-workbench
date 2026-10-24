#!/usr/bin/env bash
# Builds the `aso` command for Linux as one binary with the Swift runtime linked in, and with --window the Linux
# window (desktop/, self-contained .NET) with that binary next to it, where the window looks first.
#   scripts/package-linux.sh                         -> dist/aso-linux-x86_64.tar.gz
#   scripts/package-linux.sh --window                -> also dist/aso-workbench-linux-x86_64.tar.gz
#   scripts/package-linux.sh --aso PATH --window     packages an aso built elsewhere instead of building one
# At run time both need only the system's SQLite (libsqlite3.so.0) and libcurl; the window also needs what any
# Avalonia app needs on a desktop (fontconfig and an X11 or XWayland session).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

OUTPUT="dist"
ASO=""
WINDOW=false
while [ $# -gt 0 ]; do
    case "$1" in
        --aso) ASO="$2"; shift 2 ;;
        --window) WINDOW=true; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "Unknown option $1. Options: --aso PATH, --window, --output DIR" >&2; exit 64 ;;
    esac
done

if [ -z "$ASO" ]; then
    swift build -c release --product aso --static-swift-stdlib
    ASO="$(swift build -c release --show-bin-path)/aso"
fi
REPORTED="$("$ASO" --version)"
[ "$REPORTED" = "aso $VERSION" ] || { echo "$ASO reports \"$REPORTED\", expected \"aso $VERSION\"" >&2; exit 1; }

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

# archive NAME DIR ENTRY...: NAME.tar.gz of the entries in DIR, with NAME.sha256 beside it.
archive() {
    local name="$1" dir="$2"
    shift 2
    tar -czf "$OUTPUT/$name.tar.gz" -C "$dir" "$@"
    (cd "$OUTPUT" && sha256sum "$name.tar.gz" > "$name.sha256")
    echo "-> $OUTPUT/$name.tar.gz ($(du -m "$OUTPUT/$name.tar.gz" | cut -f1) MB)"
}

STAGE="$OUTPUT/aso-linux-x86_64"
rm -rf "$STAGE"
mkdir -p "$STAGE"
install -m 755 "$ASO" "$STAGE/aso"
cp LICENSE "$STAGE/"
archive aso-linux-x86_64 "$STAGE" aso LICENSE
echo "  $REPORTED"

if [ "$WINDOW" = true ]; then
    # Self-contained: the .NET runtime travels with the window. No trimming: Avalonia's XAML relies on reflection.
    APP="$OUTPUT/aso-workbench-linux-x86_64"
    rm -rf "$APP"
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet publish desktop/src/AsoDesktop/AsoDesktop.csproj \
        --configuration Release --runtime linux-x64 --self-contained true -p:DebugType=none --output "$APP"
    # aso goes next to the window; a name both sides ship would make one overwrite the other.
    for file in aso LICENSE; do
        [ ! -e "$APP/$file" ] || { echo "$file is shipped by both the window and aso" >&2; exit 1; }
    done
    install -m 755 "$STAGE/aso" "$APP/aso"
    cp LICENSE "$APP/"
    [ -f "$APP/ASOWorkbench" ] || { echo "The published window has no ASOWorkbench executable" >&2; exit 1; }
    chmod 755 "$APP/ASOWorkbench"
    # One folder in the archive, so unpacking it does not spill files.
    archive aso-workbench-linux-x86_64 "$OUTPUT" aso-workbench-linux-x86_64
fi

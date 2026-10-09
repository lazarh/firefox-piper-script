#!/usr/bin/env bash
# Slice 2: voice provisioning.
#
# The canonical catalogue is voices.json in the rhasspy/piper-voices repo. It
# carries each voice's language and md5 digest, so we can verify downloads
# instead of trusting them.

VOICES_INDEX_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json"
VOICES_BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"

DEFAULT_VOICE="bg_BG-dimitar-medium"

# Short list offered first in the interactive menu, before freeform entry.
POPULAR_VOICES=(
    "bg_BG-dimitar-medium:Bulgarian (Dimitar) - the default for this script"
    "en_US-amy-medium:US English (Amy)"
    "en_US-ryan-high:US English (Ryan, high quality)"
    "en_GB-alan-medium:UK English (Alan)"
    "de_DE-thorsten-medium:German (Thorsten)"
    "fr_FR-siwis-medium:French (Siwis)"
)

# Fetch the catalogue to a cache file and return its path.
# All progress output goes to stderr: callers capture stdout as the path.
voices_index() {
    # XDG_CACHE_HOME is unset in many desktop sessions, and `set -u` would abort.
    local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
    local cache="$cache_home/firefox-piper/voices.json"
    if [ ! -s "$cache" ]; then
        mkdir -p "$(dirname "$cache")"
        info "fetching Piper voice catalogue" >&2
        curl -fsSL --retry 3 --connect-timeout 20 -o "$cache" "$VOICES_INDEX_URL" \
            || die "could not download the voice catalogue from $VOICES_INDEX_URL"
    fi
    printf '%s\n' "$cache"
}

require_jq() { have jq || die "jq is required (apt-get install jq) to read the voice catalogue."; }

voice_field() {
    # voice_field <index> <voice-key> <jq-filter>
    jq -r "$3 // empty" "$1" --arg k "$2"
}

voice_language() {
    local idx=$1 key=$2
    jq -r --arg k "$key" '.[$k].language.code // "und"' "$idx"
}

voice_display_name() {
    local idx=$1 key=$2
    jq -r --arg k "$key" '.[$k].language.name_native // .[$k].language.name_english // "?"' "$idx"
}

voice_exists_in_index() {
    local idx=$1 key=$2
    [ "$(jq -r --arg k "$key" 'if .[$k] then "yes" else "no" end' "$idx")" = "yes" ]
}

# Verify a freeform key looks like the catalogue's shape before hitting the network.
validate_voice_key() {
    local key=$1
    case "$key" in
        *[!a-zA-Z0-9_-]*|'') die "Invalid voice name '$key'. Use the catalogue form, e.g. bg_BG-dimitar-medium." ;;
    esac
    printf '%s\n' "$key"
}

# The catalogue is keyed by voice key, with each file under a relative path.
voice_remote_path() {
    # voice_remote_path <index> <voice-key> <filename> -> relative path
    jq -r --arg k "$2" --arg f "$3" '.[$k].files | to_entries[] | select(.key | endswith($f)) | .key' "$1" | head -1
}

voice_file_md5() {
    # voice_file_md5 <index> <voice-key> <filename-suffix>
    jq -r --arg k "$2" --arg f "$3" \
        '.[$k].files | to_entries[] | select(.key | endswith($f)) | .value.md5_digest' "$1" | head -1
}

voice_file_size() {
    # voice_file_size <index> <voice-key> <filename-suffix>
    jq -r --arg k "$2" --arg f "$3" \
        '.[$k].files | to_entries[] | select(.key | endswith($f)) | .value.size_bytes // 0' "$1" | head -1
}

verify_md5() {
    local file=$1 expected=$2
    [ -n "$expected" ] || return 0   # no digest published; nothing to check
    local actual
    actual=$(md5sum "$file" | cut -d' ' -f1)
    [ "$actual" = "$expected" ] || { err "checksum mismatch for $(basename "$file")"; return 1; }
    return 0
}

# Download one voice's .onnx + .onnx.json into the voice store, skipping files
# already present and verified.
install_voice() {
    local key=$1
    require_jq
    validate_voice_key "$key" >/dev/null

    local idx
    idx=$(voices_index)
    voice_exists_in_index "$idx" "$key" \
        || die "Voice '$key' is not in the Piper catalogue. Check the name, or install it manually."

    local dir="$VOICE_STORE/$key"
    mkdir -p "$dir"

    local f remote local_file md5
    for f in ".onnx" ".onnx.json"; do
        local_file="$dir/$key$f"
        remote=$(voice_remote_path "$idx" "$key" "$f")
        [ -n "$remote" ] || die "Catalogue entry for '$key' has no $f file."

        if [ -s "$local_file" ]; then
            md5=$(voice_file_md5 "$idx" "$key" "$f")
            if verify_md5 "$local_file" "$md5"; then
                ok "$key$f already installed"
                continue
            fi
            warn "$key$f failed checksum, re-downloading"
            rm -f "$local_file"
        fi

        local size
        size=$(voice_file_size "$idx" "$key" "$f")
        info "downloading $key$f ($(human_size "$size"))"

        curl -fsSL --retry 3 --connect-timeout 30 -o "$local_file" "$VOICES_BASE_URL/$remote" \
            || die "failed to download $remote"

        md5=$(voice_file_md5 "$idx" "$key" "$f")
        verify_md5 "$local_file" "$md5" || die "checksum verification failed for $key$f"
        ok "$key$f installed"
    done

    # espeak-ng-data from the bundled runtime carries the `bg` dictionary; confirm
    # a non-Latin voice's dictionary is actually present before claiming success.
    local lang
    lang=$(voice_language "$idx" "$key" | cut -d_ -f1)
    if [ "$lang" != "en" ] && [ -d "$PIPER_HOME/bin/espeak-ng-data" ] \
       && [ ! -e "$PIPER_HOME/bin/espeak-ng-data/${lang}_dict" ]; then
        warn "the bundled espeak-ng-data has no ${lang}_dict dictionary; $key may mispronounce text"
    fi

    ok "voice $key ready in $dir"
}

voice_installed() {
    [ -s "$VOICE_STORE/$1/$1.onnx" ] && [ -s "$VOICE_STORE/$1/$1.onnx.json" ]
}

# List every voice installed in the voice store.
list_installed_voices() {
    local found=0 dir key
    for dir in "$VOICE_STORE"/*/; do
        [ -d "$dir" ] || continue
        key=$(basename "$dir")
        if voice_installed "$key"; then
            if [ "$found" -eq 0 ]; then log ""; log "Installed Piper voices:"; fi
            printf '  %-28s %s\n' "$key" "$(du -h "$dir/$key.onnx" 2>/dev/null | cut -f1)"
            found=1
        fi
    done
    [ "$found" -eq 1 ] || { log ""; log "No Piper voices installed yet."; return 1; }
    return 0
}

# Interactive menu: popular voices first, then freeform catalogue entry.
choose_voice_interactively() {
    require_jq
    local idx
    idx=$(voices_index)

    log ""
    log "Popular Piper voices:"
    local i entry key desc
    i=1
    for entry in "${POPULAR_VOICES[@]}"; do
        key=${entry%%:*}
        desc=${entry#*:}
        printf '  %2d) %-26s %s\n' "$i" "$key" "$C_DIM$desc$C_OFF"
        i=$((i + 1))
    done
    printf '  %2d) %-26s %s\n' "$i" "custom" "$C_DIM(type any voice name from the catalogue)$C_OFF"

    local choice
    printf '\nSelect a voice [1-%d, default 1]: ' "$i"
    read -r choice </dev/tty || choice=""
    choice=${choice:-1}

    if [ "$choice" = "$i" ]; then
        printf 'Voice name (e.g. bg_BG-dimitar-medium): '
        read -r key </dev/tty || die "no voice selected"
    else
        local n=0
        for entry in "${POPULAR_VOICES[@]}"; do
            n=$((n + 1))
            [ "$n" -eq "$choice" ] && key=${entry%%:*}
        done
        [ -n "$key" ] || die "invalid selection: $choice"
    fi

    printf '%s\n' "$key"
}
#!/usr/bin/env bash
# Point Firefox's Narrate feature at the installed Piper voice.
#
# Firefox stores its narration voice in the `narrate.voice` pref as JSON,
# mapping a language to a speech-dispatcher voice URI:
#
#   {"default":"automatic","bg":"urn:moz-tts:speechd:<name> <variant>?<lang>"}
#
# Without this, Firefox keeps requesting whichever espeak-ng voice it selected
# before, so Piper is installed and working but never spoken by.
#
# Two Firefox-side requirements, both found by reading Firefox's own code:
#
#   1. The voice must be registered with the BARE language code ("bg"), not the
#      full locale ("bg_BG"). NarrateControls filters voices with
#      `v.lang.split("-")[0] == language`, and hides the Listen button entirely
#      when that filter returns nothing.
#   2. This pref is only honoured when Firefox is closed. prefs.js is rewritten
#      from memory on exit, so edits made while the browser runs are discarded.

FIREFOX_PROFILES_DIR="${FIREFOX_PROFILES_DIR:-$HOME/.mozilla/firefox}"

# Locate Firefox profile directories that actually contain a prefs.js.
firefox_profiles() {
    local dir
    for dir in "$FIREFOX_PROFILES_DIR"/*/; do
        [ -f "$dir/prefs.js" ] && printf '%s\n' "${dir%/}"
    done
}

firefox_running() {
    pgrep -f '/firefox' >/dev/null 2>&1
}

# The voice URI Firefox expects for a voice, mirroring what the Narrate dropdown
# writes when a voice is picked by hand. Shape taken from Firefox's speechd code:
# "urn:moz-tts:speechd:%s %s" (name, variant).
piper_voice_uri() {
    local voice_key=$1 variant="${2:-FEMALE1}" lang="${3:-bg}"
    printf 'urn:moz-tts:speechd:%s %s?%s' "$voice_key" "$variant" "$lang"
}

# Rewrite narrate.voice in one profile, preserving voices for other languages.
#
# Done in python rather than awk: prefs.js holds this value as an escaped JSON
# string, and hand-rolled substitution produces malformed JSON (duplicated keys,
# stray commas) that Firefox silently fails to parse -- which leaves the voice
# unset and the Listen button hidden again.
set_narrate_voice_in_profile() {
    local prefs=$1 uri=$2 lang=$3

    have python3 || { warn "python3 is required to update $prefs"; return 1; }

    python3 - "$prefs" "$uri" "$lang" <<'PY' || return 1
import json, os, sys, tempfile

prefs, uri, lang = sys.argv[1], sys.argv[2], sys.argv[3]
PREF = "narrate.voice"

with open(prefs, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

def emit(data):
    encoded = json.dumps(data, ensure_ascii=False)
    encoded = encoded.replace("\\", "\\\\").replace('"', '\\"')
    return 'user_pref("%s", "%s");' % (PREF, encoded)

out, found = [], False
for line in lines:
    if line.startswith('user_pref("%s"' % PREF):
        data = {}
        try:
            raw = line.split(", ", 1)[1].rsplit(");", 1)[0]
            parsed = json.loads(json.loads(raw))
            if isinstance(parsed, dict):
                data = parsed
        except (ValueError, IndexError):
            data = {}
        data.setdefault("default", "automatic")
        data[lang] = uri
        out.append(emit(data))
        found = True
    else:
        out.append(line)

if not found:
    out.append(emit({"default": "automatic", lang: uri}))

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(prefs) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, prefs)
PY
}

set_firefox_voice() {
    local voice_key=$1 idx lang_short uri

    idx=$(voices_index)
    lang_short=$(voice_language "$idx" "$voice_key" | cut -d_ -f1)
    uri=$(piper_voice_uri "$voice_key" FEMALE1 "$lang_short")

    local profiles
    profiles=$(firefox_profiles)
    if [ -z "$profiles" ]; then
        warn "no Firefox profile found in $FIREFOX_PROFILES_DIR"
        dim "set it manually: Reader Mode -> Listen -> Voice -> $voice_key"
        return 1
    fi

    if firefox_running; then
        err "Firefox is running; close it first, then re-run: $0 --set-firefox-voice"
        return 1
    fi

    local prefs changed=0 p
    for p in $profiles; do
        prefs="$p/prefs.js"
        if set_narrate_voice_in_profile "$prefs" "$uri" "$lang_short"; then
            ok "set narrate voice for $(basename "$p") -> $voice_key"
            changed=1
        else
            warn "could not update $prefs"
        fi
    done

    [ "$changed" -eq 1 ] || return 1

    log ""
    ok "Firefox will narrate Bulgarian with Piper ($voice_key)"
    dim "restart Firefox, open an article, Ctrl+R for Reader Mode, then press V"
}
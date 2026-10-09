#!/usr/bin/env bash
# Slice 4: verification. Confirms the whole chain works before telling the user
# to open Firefox, so a failure is reported here rather than silently in Reader Mode.

# Speak a phrase through speech-dispatcher and report whether audio was produced.
# Checks the wrapper directly (fast, no daemon) and then via spd-say (end-to-end).
test_voice() {
    local voice_key=$1
    local model="$VOICE_STORE/$voice_key/$voice_key.onnx"

    log ""
    info "testing $voice_key"

    if [ ! -s "$model" ]; then
        err "voice model not found: $model"
        return 1
    fi

    # 1. Direct wrapper check: real audio bytes for Bulgarian text.
    local bytes
    bytes=$(printf '%s' "$TEST_PHRASE" | "$PIPER_SPEAK" --model "$model" 2>/dev/null | wc -c)
    if [ "${bytes:-0}" -lt 1000 ]; then
        err "Piper produced no usable audio (${bytes} bytes)"
        dim "try running: $PIPER_BIN --model '$model' --output_raw <<< 'тест'"
        return 1
    fi
    ok "Piper synthesised $(human_size "$bytes") of audio"

    # 2. End-to-end check through speech-dispatcher, if a daemon is reachable.
    if have spd-say; then
        if spd-say -l "$TEST_LANG" "$TEST_PHRASE" 2>/dev/null; then
            ok "speech-dispatcher accepted the request"
        else
            warn "spd-say could not reach speech-dispatcher; log in again and retry"
        fi
    fi

    log ""
    ok "verification passed"
}

# Print the manual Reader Mode check, plus what to do when it fails.
print_firefox_instructions() {
    local voice_key=$1

    log ""
    info "try it in Firefox"
    cat <<EOF

  1. Start or restart Firefox ESR.
  2. Open any article and press ${C_BLU}Ctrl+R${C_OFF} to enter Reader Mode
     (View -> Reader Mode if the shortcut is taken).
  3. Press ${C_BLU}V${C_OFF} to start narration.

  Narrated articles should now sound like Piper ($voice_key)
  rather than robotic espeak-ng.

${C_DIM}If narration is still robotic:${C_OFF}
  * Confirm the module loaded:  spd-say -L | grep -i piper
  * Check the module log:       ${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/speech-dispatcher/log/piper.log
  * Restart the daemon:         $0 --install --voice $voice_key
  * Re-run:                     $0 --test

EOF
}

# Strip the Piper runtime from PATH resolution and report what is installed.
show_status() {
    log ""
    info "firefox-piper status"

    if piper_available; then
        printf '  %-22s %s\n' "piper runtime" "$(piper_version)"
    else
        printf '  %-22s %s\n' "piper runtime" "$(printf '%snot installed%s' "$C_YLW" "$C_OFF")"
    fi

    if have firefox-esr; then
        printf '  %-22s %s\n' "firefox-esr" "$(firefox-esr --version 2>/dev/null || echo present)"
    else
        printf '  %-22s %s\n' "firefox-esr" "$(printf '%snot found%s' "$C_YLW" "$C_OFF")"
    fi

    if spd_is_configured; then
        printf '  %-22s %s\n' "speech-dispatcher" "$(printf '%sconfigured%s' "$C_GRN" "$C_OFF")"
    else
        printf '  %-22s %s\n' "speech-dispatcher" "$(printf '%snot configured%s' "$C_YLW" "$C_OFF")"
    fi

    list_installed_voices || true
    log ""
}
#!/usr/bin/env bash
#
# firefox-piper — install Piper TTS and use it for Firefox ESR Reader Mode on
# Debian 13, replacing the robotic espeak-ng narration.
#
# The chain this wires up:
#   firefox-esr  ->  speech-dispatcher  ->  sd_generic  ->  piper  ->  pw-play
#
# Everything is installed per-user: no files in /etc, and the only root access is
# apt for the packages Debian already expects you to have.
#
# Usage:
#   firefox-piper.sh                    interactive install
#   firefox-piper.sh --install          install non-interactively
#   firefox-piper.sh --install --voice bg_BG-dimitar-medium
#   firefox-piper.sh --list-voices      voices already downloaded
#   firefox-piper.sh --status           what is installed
#   firefox-piper.sh --test             verify the chain works
#   firefox-piper.sh --uninstall        remove and restore espeak-ng

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/piper.sh
. "$SCRIPT_DIR/lib/piper.sh"
# shellcheck source=lib/voices.sh
. "$SCRIPT_DIR/lib/voices.sh"
# shellcheck source=lib/speechd.sh
. "$SCRIPT_DIR/lib/speechd.sh"
# shellcheck source=lib/verify.sh
. "$SCRIPT_DIR/lib/verify.sh"
# shellcheck source=lib/uninstall.sh
. "$SCRIPT_DIR/lib/uninstall.sh"

# Per-user locations. Debian 13 targets XDG paths.
PIPER_HOME="${PIPER_HOME:-$HOME/.local/share/piper-tts}"
PIPER_BIN="$HOME/.local/bin/piper"
PIPER_SPEAK="$PIPER_HOME/piper-speak"
VOICE_STORE="${VOICE_STORE:-$HOME/.local/share/piper/voices}"
PIPER_SAMPLE_RATE=22050

# Text used by --test. Bulgarian so it exercises the same code path as a real
# article rather than a trivially short Latin string.
TEST_PHRASE="Здравей, свят. Това е Piper, който чете текста ти."
TEST_LANG="bg"

usage() {
    # Print the header comment block, minus the leading "# " and the shebang.
    sed -n '/^# firefox-piper/,/^$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^$/d'
}

# Install: preflight -> dependencies -> runtime -> voice -> configure -> verify.
do_install() {
    local voice="${1:-}"

    require_debian13
    require_espeak_fallback

    install_dependencies
    install_piper_runtime

    # Voice: explicit flag, else interactive menu, else the documented default.
    if [ -z "$voice" ]; then
        if is_interactive; then
            voice=$(choose_voice_interactively)
        else
            voice="$DEFAULT_VOICE"
            dim "no --voice given and not interactive; using default $voice"
        fi
    fi

    install_voice "$voice"

    # Mark the voice as ours so --uninstall only removes what it installed.
    : > "$VOICE_STORE/$voice/.installed-by-firefox-piper"

    configure_speech_dispatcher "$voice"
    restart_speech_dispatcher

    test_voice "$voice"
    print_firefox_instructions "$voice"
}

# Which voice is currently configured, for --test.
configured_voice() {
    [ -f "$SPD_STATE" ] || return 1
    state_get voice
}

main() {
    local command="install" voice="" uninstall_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --install)   command="install"; shift ;;
            --uninstall) command="uninstall"; shift ;;
            --test)      command="test"; shift ;;
            --status)    command="status"; shift ;;
            --list-voices) command="list-voices"; shift ;;
            --voice)
                [ $# -ge 2 ] || die "--voice needs a voice name, e.g. bg_BG-dimitar-medium"
                voice="$2"; command="install"; shift 2 ;;
            --voice=*)   voice="${1#*=}"; command="install"; shift ;;
            -h|--help)   usage; return 0 ;;
            --version)   printf 'firefox-piper (targets Debian 13, Piper %s)\n' "$PIPER_RELEASE"; return 0 ;;
            # Passed through to uninstall so flags work before or after the verb.
            --keep-voices|--purge-packages) uninstall_args+=("$1"); shift ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
    done

    case "$command" in
        install)
            do_install "$voice"
            ;;
        uninstall)
            uninstall_all ${uninstall_args[@]+"${uninstall_args[@]}"}
            ;;
        test)
            require_debian13
            local active
            active=$(configured_voice) || die "nothing configured yet; run: $0 --install"
            test_voice "$active"
            print_firefox_instructions "$active"
            ;;
        status)
            show_status
            ;;
        list-voices)
            list_installed_voices
            ;;
    esac
}

main "$@"
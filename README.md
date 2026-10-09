# firefox-piper

Use [Piper](https://github.com/rhasspy/piper) neural TTS for Firefox ESR Reader
Mode on Debian 13, replacing the robotic espeak-ng narration with natural-sounding
speech.

The chain this wires up:

```
firefox-esr  ->  speech-dispatcher  ->  sd_generic  ->  piper  ->  pw-cat
```

Everything installs **per-user**: nothing is written to `/etc`, and the only root
access is `apt` for packages Debian already expects you to have. Uninstall
restores your previous configuration and leaves espeak-ng working.

## Requirements

- Debian 13 (trixie). The script refuses to run on other releases.
- `firefox-esr` from apt
- An audio player: `pw-cat` (PipeWire, recommended), `paplay`, or `aplay`
- `curl`, `tar`, `jq`, `python3`

## Quick start

```sh
git clone <this-repo> && cd firefox-piper-script
./firefox-piper.sh --install
```

The installer shows a voice menu, downloads the voice you pick (~60 MiB for
Bulgarian), wires it into speech-dispatcher, and verifies the result.

Then **close Firefox** and point its Narrate feature at the new voice:

```sh
./firefox-piper.sh --set-firefox-voice
```

Reopen Firefox, open an article, press `Ctrl+R` for Reader Mode, then `V` to
narrate.

> **Firefox must be closed for `--set-firefox-voice`.** Firefox rewrites its
> profile preferences from memory when it exits, so a change made while it is
> running is silently discarded. The script refuses to edit rather than appear to
> succeed and lose the change.

## Commands

| Command | What it does |
| --- | --- |
| `--install` | Install Piper, the voice, and the speech-dispatcher module |
| `--install --voice NAME` | Install without the interactive menu, e.g. `bg_BG-dimitar-medium` |
| `--set-firefox-voice` | Point Firefox's Narrate at Piper (**close Firefox first**) |
| `--test` | Verify the chain end to end |
| `--status` | Show what is installed |
| `--list-voices` | List downloaded voices |
| `--uninstall` | Remove Piper and restore espeak-ng |

`--uninstall` accepts `--keep-voices` (leave the voice models on disk) and
`--purge-packages` (also remove the apt packages). espeak-ng is deliberately
never removed, so you always keep a working voice.

Running the script with no arguments prints this help.

## What gets installed

| Path | Contents |
| --- | --- |
| `~/.local/bin/piper` | Piper runtime wrapper |
| `~/.local/share/piper-tts/` | Piper binaries, libraries, espeak-ng data |
| `~/.local/share/piper/voices/<voice>/` | Voice model (`.onnx`) and its config (`.onnx.json`) |
| `~/.local/share/piper-tts/piper-speak` | Generated synthesis wrapper |
| `~/.config/speech-dispatcher/speechd.conf` | Generated main config (prior one backed up) |
| `~/.config/speech-dispatcher/modules/piper.conf` | Generated `sd_generic` module config |

The previous `speechd.conf` is saved as `speechd.conf.firefox-piper.bak` and
restored on uninstall.

## Voices

Voices come from the [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices)
catalogue, which publishes an MD5 digest for every file. Downloads are verified
against it rather than trusted.

The default is `bg_BG-dimitar-medium` (Bulgarian). Pass `--voice` with any
catalogue key to use another, for example `en_US-amy-medium`.

## Notes

**Debian 13 has no `piper-tts` package.** The runtime is fetched from the upstream
GitHub release archive, which bundles its own `onnxruntime`, `libespeak-ng` and
`espeak-ng-data` — including the `bg` dictionary Bulgarian voices need. Nothing
else is required.

**Latency.** The model loads per utterance (~0.4 s before the first word). That is
fine for reading articles, but noticeable if you narrate very short strings.

**`spd-say -L` does not list Piper voices the way it lists espeak's.** That is
normal for an `sd_generic` module and not a sign of failure.

**Audio player.** `pw-play` cannot be used here: it takes a filename, not a PCM
stream, so piping into it fails. The script uses `pw-cat --playback --raw`
instead, falling back to `paplay` or `aplay`.

## How it works

Piper is exposed to speech-dispatcher as an `sd_generic` module. The module
receives text on a pipe, hands it to a generated `piper-speak` wrapper, and streams
raw PCM to the audio player.

Three details were found by testing against speech-dispatcher 0.12.1 rather than
assumed, and each one breaks narration if wrong:

- **`$DATA` must be single-quoted** in `GenericExecuteSynth`. The double-quoted
  form mangles apostrophes in article text (`it's` arrives as `it'\''s`) and
  silently strips double quotes.
- **`GenericDefaultCharset "utf-8"` is required.** Without it, `sd_generic`
  recodes the utterance and every non-Latin character becomes `?` — which
  destroys Bulgarian text entirely.
- **Voices must be registered under the bare language code** (`bg`, not `bg_BG`).
  Firefox's Narrate UI filters voices with `v.lang.split("-")[0] == language` and
  hides the Listen button entirely when nothing matches.

Firefox also stores its narration voice in the `narrate.voice` preference as a
JSON map of language to voice URI. It keeps requesting whatever voice it had
before, so `--set-firefox-voice` updates that map (preserving voices for other
languages) rather than relying on the module default.

## Troubleshooting

**No Listen button in Reader Mode.** Check that the voice is visible:

```sh
spd-say -L | grep dimitar      # language column must read "bg", not "bg_BG"
```

**Narration sounds robotic.** Firefox is still using espeak-ng. Confirm
`narrate.voice` points at Piper:

```sh
grep narrate.voice ~/.mozilla/firefox/*/prefs.js
```

Then close Firefox and re-run `--set-firefox-voice`.

**Nothing happens at all.** Check the module log at
`$XDG_RUNTIME_DIR/speech-dispatcher/log/piper.log`.

**Audio is wrong speed or pitch.** The player is fed at the voice's own sample
rate (22050 Hz for `dimitar-medium`), read from the model's `.onnx.json` rather
than hardcoded.

## License

The Piper runtime and voice models are downloaded at install time and carry their
own licenses — see [piper](https://github.com/rhasspy/piper) and
[piper-voices](https://huggingface.co/rhasspy/piper-voices).
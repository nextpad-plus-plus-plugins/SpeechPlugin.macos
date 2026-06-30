# SpeechPlugin (macOS port)

Text-to-speech for **Nextpad++** (the macOS port of Notepad++). Reads the current
document or selection aloud.

macOS port of the Windows "Speech" plugin by Jim Xochellis
([SourceForge npp-plugins](https://sourceforge.net/projects/npp-plugins/files/SpeechPlugin/)),
licensed GPL v2 (see `LICENSE`).

## Menu commands (Plugins ▸ Speech)

| Command | Action |
| --- | --- |
| Speak Selection | Speak the current selection (alerts if nothing is selected) |
| Speak Document | Speak the whole active document |
| Stop Speech | Stop and clear current speech |
| Pause Speech | Pause playback |
| Resume Speech | Resume after a pause |
| Voice & Rate… | Pick a system voice and speaking rate (with Preview); persisted |

## How it differs from the Windows version

The Windows plugin drives **Microsoft SAPI 5** (COM `ISpVoice`). This port uses the
native macOS **AVFoundation `AVSpeechSynthesizer`** engine instead — no extra
runtime, no installed-language download step. All five original commands are
preserved; the **Voice & Rate** picker is a macOS addition (the v0.6 Windows
plugin had no voice UI), made trivial by AVFoundation exposing the installed
system voices and a speaking rate.

| SAPI (Windows) | AVFoundation (macOS) |
| --- | --- |
| `ISpVoice::Speak(SPF_ASYNC \| SPF_PURGEBEFORESPEAK)` | `stopSpeakingAtBoundary:` (purge) + `speakUtterance:` (async) |
| `ISpVoice::Pause()` | `pauseSpeakingAtBoundary:Immediate` |
| `ISpVoice::Resume()` | `continueSpeaking` |
| `ISpVoice::Release()` (stop) | `stopSpeakingAtBoundary:Immediate` |

Voices are the ones installed in **System Settings ▸ Accessibility ▸ Spoken
Content ▸ System Voice ▸ Manage Voices**. The chosen voice + rate are saved to
`SpeechPlugin.ini` under the host's per-plugin config directory.

## Build

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Produces a universal (`arm64;x86_64`) `SpeechPlugin.dylib`. `cmake --install build`
copies it to
`~/Library/Application Support/Nextpad++/plugins/SpeechPlugin/SpeechPlugin.dylib`.

# Edvvrdd Reaper tools for Game audio

Two REAPER scripts for game audio, installable via ReaPack.

## Tools

- **ReaBlender** — Unified Sound/Dev/Ed suite: one-button multiband LR4 rig (Sub / Low-Mid / High-Mid / Air buckets) + granular whoosh engine in one polished UI. Auto-Whoosh generation from a time selection, Live performance mode (looping transport + virtual playhead), per-bucket ingredient management, stem rendering. Ships `ReaBlender.lua`, `ReaBlender_Filter.jsfx`, `ReaBlender_Brain.jsfx`, `ReaBlender_Visualizer.jsfx`. Requires [ReaImGui](https://github.com/cfillion/reaimgui).
- **QikWhoosh** — Granular whoosh generator. Use your session's audio items as the source library, make a time selection, and generate whooshes with editable volume/pitch/pan/filter envelopes. Requires [ReaImGui](https://github.com/cfillion/reaimgui).
- **Create_Or_Sync_Multiband_Rig** (legacy) — the original 3-band rig builder, superseded by ReaBlender; kept for existing projects.
- **CurveGenerator** — Turns a REAPER audio item into a haptic curve and exports it for Unreal (CSV), Unity (AnimationCurve JSON), or Godot 4 (`.tres`). Requires [ReaImGui](https://github.com/cfillion/reaimgui).

## Install

1. Install [ReaPack](https://reapack.com)
2. In REAPER: **Extensions → ReaPack → Manage repositories → Import/export → Import repositories**
3. Paste:

```
https://raw.githubusercontent.com/Edvvrdd/ReaperTools/main/index.xml
```

4. **Extensions → ReaPack → Synchronize packages** — both scripts appear in the Actions list

## License

MIT

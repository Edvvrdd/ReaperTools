# Edvvrdd Reaper tools for Game audio

Two REAPER scripts for game audio, installable via ReaPack.

## Tools

- **QikWhoosh** — Granular whoosh generator. Use your session's audio items as the source library, make a time selection, and generate whooshes with editable volume/pitch/pan/filter envelopes. Requires [ReaImGui](https://github.com/cfillion/reaimgui).
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

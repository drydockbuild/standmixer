# StandMixer mark

The countertop mixer rests on a single Drydock amber underline. There is no separate teal plinth. The 64-unit geometry is shared by the header, native panels, Dock icon, and website.

- Light surfaces: teal `#0E9488`, amber `#F59E0B`.
- Dark surfaces: muted teal `#6FB3B8`, amber `#F59E0B`.
- Dock tile: off-white `#F8FAFB`, navy edge `#0B1220` at 7%.
- Use `standmixer-mark.svg` on light surfaces, `standmixer-mark-dark.svg` on navy, and `standmixer-icon.svg` for the tile. Keep the underline and silhouette together.

The Mac app uses the static navy ICNS generated with `dev/make-icon.swift`. macOS displays the bundled icon in Finder, the Dock, and the standard About panel, including its system tint treatment. `standmixer-icon-dark.svg` is the matching master.

Codex sidebar entrypoints embed transparent PNGs so the host preserves their colors instead of treating them as monochrome SVG masks. Regenerate the PNGs, embedded metadata, and preview with `swift dev/make-sidebar-icons.swift .`.

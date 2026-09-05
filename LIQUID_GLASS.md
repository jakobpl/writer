# Liquid Glass implementation notes

mac_pastebin targets macOS 26 and uses native SwiftUI Liquid Glass APIs. Start with Apple's documentation:

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)

## Notes from mac_pastebin's UI iteration

- Use native SwiftUI `glassEffect(_:in:)` for custom glass surfaces when targeting macOS 26+.
- Prefer applying glass to a small number of meaningful containers: tool islands, sidebars, lock cards, and key controls.
- Do not apply full glass styling recursively to every nested label/button. In this app, glass-inside-glass made small control labels foggy and low contrast.
- Keep writing content on a stable, high-contrast surface. Liquid Glass can frame the writing area, but the note body should remain easy to read for long sessions.
- For custom surfaces, combine native glass with a subtle tint overlay, a hairline stroke, and a soft shadow. The tint is needed because fully clear glass can lose contrast over bright or busy backgrounds.
- Use smaller floating islands instead of one full-width toolbar slab. The app feels more minimal when the brand/status and controls sit in separate glass groups.
- Avoid large system focus rings over custom sidebars. Keep keyboard focus behavior, but suppress the visual ring when it overpowers the Liquid Glass surface.
- Use color sparingly: aquamarine for primary/secure actions, amber for status, otherwise monochrome controls.
- If the app window can render over a bright or empty backdrop, provide a restrained shared blue/green app backdrop behind the glass. Fully transparent root backgrounds made offscreen and bright-wallpaper states too pale; heavy opaque tints made the UI feel like dark panels instead of glass.
- Keep glyphs above glass layers. Applying `glassEffect` directly to an icon view can make the symbol disappear or lose contrast in snapshots; use a glass shape as the background and place the SF Symbol in a separate foreground layer.
- Custom password/title fields should use `.plain` text field styling plus app chrome. Default rounded text fields bring a strong macOS focus ring that clashes with the Liquid Glass surface.

## Current reference direction

- Use the root images `desired_ui_inspiration__locked.png` and `desired_inrpiration_unlocked.png` as the design target.
- Locked state works best as one large frosted window pane with very few controls: centered lock badge, password pill, and start-new-vault pill.
- The unlocked editor should avoid a brand/header slab. Let floating puffy controls sit near the top-right, then give most of the window to the notes glass pane and paper editor.
- Large glass needs a visible white rim, a soft inner highlight, and a restrained tint. Without the rim, it reads as flat translucent color; with too much tint, it becomes an opaque panel.
- Iridescent bloom overlays should be subtle and clipped to large glass surfaces only. They help sidebars feel liquid without reducing text contrast.
- Snapshot renders are useful for layout and hierarchy, but live macOS screenshots are still needed for final material tuning because desktop wallpaper and real window blur affect perceived glass strength.

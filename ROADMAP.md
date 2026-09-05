# mac_pastebin roadmap

These initiatives are intentionally deferred. They are design notes, not commitments or partially implemented features. The [README](README.md) describes what the app supports today.

## Media-only vault

1. Add an explicit vault kind so a vault is either a notes vault or a media vault.
2. Store an encrypted manifest and independently encrypted, authenticated, chunked assets so importing or editing one large video does not rewrite every asset.
3. Import original resources without transcoding. Preserve HEIF/HEIC, MOV, Live Photo image/video pairs, metadata, filenames, and available sidecar resources.
4. Hash every resource before encryption and after decrypt/export. An import is complete only when a byte-identical verification succeeds.
5. Use a crash-safe staging area, atomic manifest commits, resumable imports, disk-space checks, and encrypted thumbnail data. Do not leave decrypted preview or thumbnail caches on disk.
6. Test interrupted and resumed imports, duplicate assets, large videos, disk-full failures, backup/restore, Live Photo pairing, and byte-identical export.

## UI improvements

1. Add an intermediate successful-unlock presentation state and animate the lock symbol opening before revealing the editor. Respect Reduce Motion with a short opacity transition.
2. Replace hard-coded colors with semantic theme tokens. Support persisted Light, Dark, and Sepia choices on both the unlock and editor screens, with Sepia matching the current appearance.
3. Add a reusable pointing-hand hover modifier for enabled buttons, note rows, formatting controls, recovery actions, and other clickable custom surfaces. Restore the previous cursor on exit and preserve keyboard focus and accessibility behavior.
4. Add visual and accessibility regression coverage for every theme, successful and failed unlocks, reduced motion, disabled controls, keyboard navigation, and hover entry/exit.

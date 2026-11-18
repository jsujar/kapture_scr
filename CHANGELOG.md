# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added
- **Language menu** (*Options › Language*): choose any of the 15 languages, or *Same as System*. The choice is stored as the app's own `AppleLanguages`, the same setting as System Settings › Language & Region › Applications. Kapture SCR restarts to apply it; when the in-memory history holds screenshots or imported images it warns that they will be lost and offers *Later*.
- **Five new languages:** German, Norwegian (Bokmål), Swedish, Hungarian and Traditional Chinese (Taiwan vocabulary), for 15 in total.

### Fixed
- **Right-to-left layout** for Arabic and Urdu chosen for the app only: macOS takes the layout direction from the system language, so Kapture SCR now sets it from its own language at launch (and keeps other languages left-to-right on an Arabic or Urdu Mac). In the watermark settings, the preview, the nine positions and the horizontal slider stay left-to-right because they match places in the image.
- **Automatic watermark** (*Options › Watermark Settings…*, off by default): adds an image of your choice to every capture and imported image, in files, the clipboard and the editor. Live preview on a sample screenshot where the mark can be dragged, nine quick positions, horizontal and vertical position in percent (the mark always stays inside), size as a share of the capture's width, opacity, and *Repeat as a pattern*. The image (PNG, JPEG, HEIC or TIFF up to 4096 px) is copied into the sandbox container. *Options › Add Watermark* turns it on and off. JPEG files with a watermark are flattened onto white. Translated into all 10 languages.

### Development
- **Unit tests** (`swift test`, 76 tests): image limits, history, edits and undo, watermark, file saving, shortcuts and the 15 translations, plus a three-layer check that the app cannot reach the network (entitlements, source and compiled binary).
- **Continuous integration** on GitHub Actions: tests, code coverage, translation check and a signed build whose entitlements are checked for the sandbox and the absence of network access.
- **Load test** (`scripts/loadtest/run.sh`) and **coverage report** (`scripts/coverage.sh`).
- `CaptureStore.expire(now:)` takes the current time as a parameter so expiry can be tested.

### Added
- **Adjustable selection**, optional (*Options › Adjust Capture Area*, off by default; when off, releasing the mouse captures at once as before). When on, releasing the mouse no longer captures at once. The area keeps eight handles (edge handles hide on short sides); corners and edges resize it with the system resize cursors, dragging inside moves it, dragging outside starts a new one, and arrow keys nudge it (⇧ ×10, ⌥ resizes). The glass hint anchors under the area (above it, or inside, when there is no room) and gains a *Capture* button; Return or a double-click also confirm.
- **New logo** (approved version, `logo/KaptureSCR_Assets_PNG_Aprobado_v2/`): carbon-grey and gold frame around the hat-and-cursor symbol. The app icon (Dock, Finder, editor empty state; full `AppIcon.icns` from 16 to 1024 px) places the artwork on the standard macOS grid (824 px continuous-corner tile on a 1024 canvas, soft shadow and a faint rim so the black tile reads on a dark Dock); the kit's tile filled the whole canvas and showed a slightly lighter square around the artwork, so the artwork is flattened onto pure black. The menu bar uses a monochrome template derived from the same artwork at its true proportions (pixel bar kept as half-tone) that macOS tints for light, dark and highlighted states. Derived files are in `07_Kapture_Ajustado/`; the README header uses the horizontal logo.
- **Configurable import shortcut:** *Options › Change Import Shortcut…* records a new combination for importing from the clipboard (default ⌘⇧E), with the same rules as the capture shortcuts; the menu item shows the current one.
- **Capture Window** action with its own global shortcut (default ⌘⇧7, configurable from *Options › Change Window Shortcut…*): opens the system window picker regardless of the selected capture mode. Each action rejects shortcuts already used by the other.
- **Custom capture shortcut:** menu › *Options* › *Change Capture Shortcut…* opens a small glass recorder. Requires two modifiers including ⌘ or ⌃ (function keys excepted), rejects shortcuts reserved by macOS, the import shortcut and ones another app holds, and offers *Restore Default* (⌘⇧6). The menu, the empty states and the welcome message show the current shortcut.
- **Capture guide** in Selection mode: a small Liquid Glass hint next to the pointer that invites you to press <kbd>Space</kbd> for options; <kbd>Esc</kbd> cancels. Hidden while dragging.
- **Options panel** opened with <kbd>Space</kbd>: the hint morphs into a glass panel to choose a timer of none, 3, 5 or 15 seconds (mouse or <kbd>←</kbd>/<kbd>→</kbd>). <kbd>Space</kbd>/<kbd>Return</kbd>/<kbd>Esc</kbd> close it; a second <kbd>Esc</kbd> cancels the capture. The choice is saved as the timer preference.
- **Glass countdown** with progress ring for delayed Selection and Full screen captures, centred on the captured area; <kbd>Esc</kbd> cancels. It replaces `screencapture -T` for those modes (Window mode still uses the system timer).
- **Redesigned recent captures panel** (menu bar hover): smoked Liquid Glass panel that hangs right under the icon with a short fade/slide, dark capsule controls ("Recientes: N", Importar, Carpeta, Editor, Auto imágenes, Vaciar), concentric rounded thumbnails with hover lift and age label, and an empty state with the capture shortcut.
- **Redesigned editor window**: dark canvas under a transparent title bar; floating smoked-glass toolbar level with the window buttons (undo/redo, tool selector with icons and a sliding accent selection, Copiar, Guardar copia, import, and a "more" menu for Eliminar / Vaciar); text field for the Text tool appears under the toolbar; glass filmstrip of captures at the bottom; status messages shown as a glass toast that fades after 4 s; new empty state. Tool shortcuts ⌘1–⌘4. Images are no longer upscaled beyond their size.
- Liquid Glass on macOS 26+ (`glassEffect`, `glassEffectID`, `GlassEffectContainer`), regular material fallback on macOS 14–15; animations honour *Reduce motion*.

- **Localization** into the 10 most spoken languages: English (development language), Spanish, French, Portuguese (Brazil), Russian, Simplified Chinese, Hindi, Bengali, Arabic and Urdu (right-to-left). Strings use English keys via `L(...)`; translations in `Resources/*.lproj/Localizable.strings`; `scripts/check-strings.py` reports missing or unused keys.
- **Light and dark appearance** for every glass surface (capture guide, countdown, recent captures panel, editor), following the system setting.

- **Disk image:** `scripts/make-dmg.sh` builds `dist/Kapture SCR <version>.dmg` with a drag-to-Applications window, instructions for the first launch on Macs where the app is not notarized, and the app icon as the volume icon.

### Changed
- Empty states of the editor and the recent captures panel show the horizontal logo with the app name (background removed, enclosed blacks kept; `07_Kapture_Ajustado/Logo_Horizontal_Transparente_1602x473.png`) and list both shortcuts (*Take Screenshot* and *Capture Window*) and update when they change.
- Editor toolbar: tool names collapse to icons when they do not fit, and button titles never truncate, so long translations stay readable.
- The capture guide now **follows the pointer** (below-right, flipping at screen edges and mirrored in right-to-left languages). The options panel stays where it was opened so it can be clicked; ← → follow the reading direction. It lives in its own non-key panel above the overlay.
- File names no longer contain Spanish words: `Kapture SCR YYYY-MM-DD HH.MM.SS`; edited copies are named `… (edited)` in the current language.
- Timer choices are now none / 3 / 5 / 15 seconds (were none / 5 / 10). A saved 10 s timer resets to none.
- Focus returns to the previous app after the selection and countdown, right before the shot.
- Product renamed to **Kapture SCR** (app name, menus, window title, file names `Kapture SCR YYYY-MM-DD …`, app bundle `Kapture SCR.app`). The bundle identifier `local.kapture.app`, the executable `Kapture` and the signing certificate keep their names, so the Screen Recording permission is preserved.
- The menu item that opens the recent captures panel is now *Show Recent*.
- **Lower idle energy use:** the app no longer wakes up periodically. Hovering the menu bar icon is detected with tracking areas instead of a 0.35 s timer; the clipboard is checked (every 0.5 s, with timer tolerance) only while *Auto images* is on; expired captures are removed by a single timer set for the oldest one instead of a check every 5 s.

## [0.3.0] – 2026-11-17

Turned into a full screenshot tool.

### Added
- **Own capture command**, <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>6</kbd> (global hotkey) and menu › *Capturar*, using `/usr/sbin/screencapture`.
- **Capture modes:** Selection, Window and Full screen.
  - Selection uses Kapture's own full-screen overlay (white crosshair with black outline, no coordinates) and then `screencapture -R`. <kbd>Esc</kbd> cancels; the timer starts after the selection is made.
- **Destinations:** Clipboard, Folder, or Clipboard and folder. The folder is chosen with an open panel and remembered with a security-scoped bookmark.
- **Options submenu:** timer (none / 5 s / 10 s), format (PNG / JPG), show cursor, window shadow.
- **Persistent preferences** (`UserDefaults` inside the sandbox container): mode, destination, folder, timer, format, cursor, shadow.
- **Floating thumbnail** in the top-right corner of the screen under the pointer for 5 s after each capture; click to open in the editor, hover to keep it.
- **Save copy** (<kbd>⌘</kbd> <kbd>S</kbd>) in the editor: writes a new `…-editada.png` to the chosen folder (or asks where); the original is never modified.
- File naming `Kapture YYYY-MM-DD a las HH.MM.SS.<ext>` with automatic de-duplication (never overwrites).
- Screen Recording permission check (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`) with guidance message.
- Build script signs with a local self-signed certificate ("Kapture Local Signing") when available so the Screen Recording grant survives rebuilds, and installs to `~/Applications`.

### Changed
- Bundle identifier `local.kapture.app`, app name and executable `Kapture`, version 0.3.0 (build 3).
- Menu bar icon is the SF Symbol `camera.viewfinder`.
- The menu is rebuilt on demand (`NSMenuDelegate`) to reflect current settings.
- Own captures accept larger images (up to 16384 px per side, 50 MP) than clipboard imports (8192 px, 16 MP, 48 MiB).
- The clipboard always receives lossless PNG even when files are saved as JPG.

### Removed
- The <kbd>⌃</kbd> <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>4</kbd> "capture to clipboard" instructions (system shortcut) in favour of Kapture's own capture command.

### Security / privacy
- Entitlements now include `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`, limited to the folder the user picks. Still no network entitlement.
- Kapture now writes files (captures, edited copies, preferences). Capture temporary files live in the container and are deleted after reading.

## [0.2.0] – 2026-11-13

### Added
- Global shortcut <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>E</kbd> to import the clipboard image and open the editor (Carbon `RegisterEventHotKey`, no keyboard monitoring, no Accessibility permission).
- **Recent captures panel** shown when hovering over the menu bar icon (and from the menu); thumbnails can be dragged into other apps.
- Optional **Auto images**: polls the pasteboard `changeCount` and imports new PNG/TIFF images. Off at launch, not persisted, paused while the editor is visible.
- **Undo / redo** in the editor (up to five states, 64 MiB budget).

### Changed
- Editing history is discarded when switching images.

## [0.1.0] – 2026-11-13

First prototype.

### Added
- Menu bar app with a window of thumbnails.
- Manual import of PNG/TIFF images from the clipboard; known private pasteboard markers are excluded; text, HTML and URLs are rejected.
- Editor with crop, arrow, text and opaque redaction (destructive, no undo).
- Copy the result as a rasterized PNG without the original's metadata.
- Ephemeral in-memory history: 10 items, 30 minutes, 128 MiB raster budget.
- App Sandbox with no network entitlement; ad hoc local signing.


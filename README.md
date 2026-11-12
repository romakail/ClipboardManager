# ClipboardManager

A background clipboard history manager for macOS: press **⇧⌘V** anywhere to bring up a
searchable, full-width history of everything you've copied — text, links, and images —
and paste any of it back with a normal **⌘V**.

No Xcode required to build or run it — just the free Command Line Tools (see below).

## Installing on a new Mac

1. **Install the Xcode Command Line Tools** (skip if you already have Xcode or the tools
   installed — check with `xcode-select -p`):

   ```
   xcode-select --install
   ```

   This opens a small installer dialog; let it finish before continuing.

2. **Clone this repository**:

   ```
   git clone https://github.com/romakail/ClipboardManager.git
   cd ClipboardManager
   ```

3. **Build it**:

   ```
   ./build.sh
   ```

   This compiles the app and produces `ClipboardManager.app` in this folder, then
   launches it automatically.

4. **Install it permanently**: drag `ClipboardManager.app` into `/Applications`.

5. **(Optional) Start it automatically at login**: click the clipboard icon in the menu
   bar (top right of your screen — there's no Dock icon) and choose **Launch at Login**.

To update later: `git pull`, then run `./build.sh` again (from `/Applications` if that's
where you moved it, or re-drag the freshly built app there afterward).

## Usage

- **⇧⌘V (Shift-Command-V)** — open/close the history panel at the bottom of the screen.
  Opening the app again while it's running does the same.
- **Left / Right arrows** — move through history.
- **Enter, or click an item** — paste it straight into the app you were in (see *Direct
  paste* below; without it, the item is copied and you press **⌘V** yourself).
- **⇧Enter** — the same, as plain text (formatting stripped).
- **⌘1 … ⌘9** — paste the 1st–9th visible item immediately. Hold **⌘** to see the numbers.
- **⌘C** — copy the highlighted item without pasting it.
- **Just start typing** — search. Words match the content, the type, or the source app, so
  `safari link docs` finds a docs link copied from Safari. **⌘F** also focuses the field.
- **Tab / ⇧Tab**, or click a chip — filter by type: All, Text, Links, Images, Colors.
- **Space** — Quick Look preview of the highlighted item (images, text and links).
- **⌘Return** — open the highlighted item in your browser if it's a link.
- **⌘S** — keep the highlighted item in the Saved row; **Down** shows that row, **Up** hides it.
- **Delete** (or **⌘Delete** while searching) — remove the highlighted item.
- **Right-click** an item for all of the above as a menu. Drag items to reorder them.
- **Esc** — close a preview / clear the search / close the panel.

### Direct paste

To have Enter paste into the app you came from, choose **Paste Directly into Active App**
from the menu bar icon and allow ClipboardManager under *System Settings → Privacy &
Security → Accessibility*. macOS ties that permission to the exact build, so after
rebuilding with `./build.sh` you may need to remove and re-add the app in that list.

### Privacy

Content that apps mark as concealed or transient (password managers do this) is never
recorded. **Pause Capturing** in the menu bar menu stops recording until you resume, and
**Clear History…** erases everything except your saved items.

History (up to 1000 items, including images) is saved locally to
`~/Library/Application Support/ClipboardManager/` and survives restarts. Nothing is sent
anywhere over the network.

## Project structure

```
Package.swift               Swift Package Manager manifest (no external dependencies)
build.sh                    Builds and packages the app into ClipboardManager.app
Packaging/Info.plist        App bundle metadata (background/menu-bar app, no Dock icon)
Sources/ClipboardManager/
  main.swift                 Entry point
  AppDelegate.swift           Menu bar item, wiring
  Models/                     ClipboardItem
  Storage/                    History persistence, image storage, on-disk paths
  Clipboard/                  Pasteboard monitoring and writing
  HotKey/                     Global ⇧⌘V hotkey registration
  UI/                         The history panel and its views
  Utilities/                  URL detection, hashing, app icon/color resolution
```

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
   git clone https://github.com/<your-username>/ClipboardManager.git
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
- **Left / Right arrows** — move through history.
- **Enter, or click an item** — move it to the top and copy it to the pasteboard; then
  press **⌘V** normally in whatever app you're using to paste it.
- **Space** — preview the highlighted item if it's an image (opens Quick Look).
- **⌘Return** — open the highlighted item in your browser if it's a link.
- **⌘F** — jump to the search bar and filter your history by text.
- **Esc** — clear search / close a preview / close the panel.

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

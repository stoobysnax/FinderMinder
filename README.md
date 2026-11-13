# FinderMinder

A small macOS menu bar app that keeps Finder's **column view** columns wide
enough to show long file names in full.

Whenever you open a folder or move around in a column-view window, FinderMinder
sizes each visible column to fit its longest name, plus some room for badges such as
Dropbox's check mark. It measures the names in Finder's font, then drags each column's
resize grip (‖) once, straight to the right width. Columns that are already right don't
move. Then it puts your mouse pointer back where it was.

## Build and install

You need macOS 13 (Ventura) or later and the Xcode Command Line Tools
(`xcode-select --install`).

```bash
./build-app.sh
```

```bash
mv build/FinderMinder.app /Applications/ && open /Applications/FinderMinder.app
```

On first launch macOS asks you to allow FinderMinder in
**System Settings → Privacy & Security → Accessibility**. Turn it on. FinderMinder needs this
to read Finder's columns and to click their resize grips. FinderMinder starts working as soon
as you allow it.

> The build is ad-hoc signed. If you rebuild, macOS may treat it as a new app. In that case,
> remove FinderMinder from the Accessibility list and add it again.

## Menu

| Item | What it does |
| --- | --- |
| Auto-Fit Column Widths | Turns automatic resizing on or off. |
| Fit Columns Now | Resizes the frontmost Finder window's columns once. |
| Extra Width | Adds room after the longest name so badges such as Dropbox's sync check mark aren't cut off. The default is 24 points. |
| Minimum Width | **Tight** fits each column to its names. **Wider** also keeps every column at least about 250 points wide, even when the names are short. |
| Launch at Login | Starts FinderMinder when you log in. The app must be in /Applications. |
| Reset Grip Calibration | Searches for the grip position again. |
| Copy Diagnostics | Copies what FinderMinder sees in the front Finder window to the clipboard. |

## How it works / safety

- FinderMinder only acts when Finder is the frontmost app and its focused window is in column view.
- It skips a pass while you hold a mouse button or a modifier key, or while you rename a file.
- It re-fits only when the window shows *different content*: a new folder, column or selection.
  If you drag a column to a custom width, FinderMinder leaves that width alone until you navigate.
- Before every click, it asks Accessibility which element is under that point. It clicks only
  when that point is inside Finder's column browser and not on a file, name, icon, button or
  scroll bar. So it never opens a file by mistake.
- The first time it runs, it double-clicks near the bottom of a column divider to find the
  grip, and to learn how much space Finder leaves after a name. It saves both and doesn't
  double-click again.

## Troubleshooting

If columns don't resize, first resize a column by hand so its name gets cut off. Then choose
**Reset Grip Calibration** and then **Fit Columns Now**. If that doesn't help, choose
**Copy Diagnostics** and paste the result into an issue.

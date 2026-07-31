# Version Up

Duplicate selected timelines with an incremented version number and file the originals away into a Versions bin. No dialog, no options; select, run, done. Ideal on a keyboard shortcut or Stream Deck via [Script Launcher](script_launcher.md).

- [Installation Guide](#installation-guide)
- [Usage Guide](#usage-guide)
- [Things to Know](#things-to-know)
- [Compatibility](#compatibility)
- [License](#license)

### Get the installer from the [latest release](https://github.com/oliwiergesla/editorscripts/releases/latest)

<img src="../assets/EditorScripts_Installer.png" alt="EditorScripts Installer" width="100%">

## Installation Guide

Version Up is part of the [EditorScripts](../README.md) toolkit, and every script ships in one installer file:

1. Download the installer from the [latest release](https://github.com/oliwiergesla/editorscripts/releases/latest).
2. In DaVinci Resolve, open the **Fusion** page.
3. Drag the installer file anywhere into the Fusion page.
4. Click **Install** to get everything, or **Custom Installation** to pick individual scripts.

> [!NOTE]
> The installer is not a standalone program. Like the scripts it installs, it is a small script file that runs inside Resolve.

**Updating:** download the latest installer and drag it in again; it updates outdated scripts and skips anything already up to date.

## Usage Guide

Version Up works with almost any name, but it is most reliable when timelines follow a consistent convention with the version at the very end, for example `TimelineName_3840x2160_V1`.

Version Up only ever touches the version part of the name (like `_V1`), so the rest passes through untouched, and the same layout plays nicely with [Reframe](reframe.md) when it rewrites resolution and version suffixes.

Select one or more timelines in the Media Pool, then run **Workspace → Scripts → EditorScripts → Version Up**. For each selected timeline it:

1. **Detects the version in the name and bumps it by one.** All the common styles are recognized: `_V1`, `-v2`, `(v3)`, `[V4]`, `V5` at the end, `_version6`, dot and space separated forms, and versions in the middle of the name. Zero-padding (`V01` → `V02`), upper/lower case, and the version's position in the name are all preserved.
2. **Appends `_V02` when no version is found**, treating the unversioned original as version 1.
3. **Duplicates the timeline under the new name** and moves the original into a **Versions** bin inside the Media Pool folder you're currently browsing, creating the bin if needed. The new version stays where the original was.

## Things to Know

> [!IMPORTANT]
> **No confirmation and no undo.** Aside from the name-conflict warning, the batch starts the moment the script runs; moving originals back out of the Versions bin is a manual job.

- **The rightmost version wins.** In `Timeline_V1_Master_V3`, only `V3` is bumped; earlier version-like parts of the name are left alone.

- **Some patterns aren't detected.** Space-separated versions mid-name (`My Timeline V2 Final`), bracketed versions away from the end, and non-integer versions like `V1.5` are not recognized.

- **Existing names trigger a warning.** Resolve refuses to create a timeline under a name that already exists, so when a bumped name is taken the script shows a dialog before touching anything: **Cancel** stops the whole batch untouched, and **Use Next Available Version** continues with the smallest free version above the bump (versioning `_V2` while `_V3` and `_V4` exist creates `_V5`). This also covers two selected timelines that would bump to the same name.

- **You end up parked on the last duplicate.** Resolve always makes the new duplicate the current timeline, and the script can't put you back on the one you had open.

## Compatibility

- **DaVinci Resolve:** **Studio** 20 and newer. The free version of DaVinci Resolve is not supported.
- **Platforms:** macOS, Windows. Linux is untested.

## License

[GPL-3.0](../LICENSE) © 2026 Oliwier Gesla

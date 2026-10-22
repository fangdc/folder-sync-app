[简体中文](README.md) · [English](README.en.md)

# FolderSync

One-way sync from a folder on your Mac to an external drive or any other folder.

Pick a source folder and a destination folder; FolderSync creates a subfolder with the
same name inside the destination and keeps its contents in sync. Nothing else in the
destination folder is touched.

**[Download the latest release](https://github.com/fangdc/folder-sync-app/releases/latest)** · macOS 14 or later · Universal (Intel & Apple silicon)

---

## Features

| Feature | Details |
| --- | --- |
| Auto-created subfolder | Choose a source and a destination; files are written to `destination/source-folder-name/` |
| Two sync modes | **Incremental** (default; only additions and changes) / **Mirror** (destination matches source exactly, including deletions) |
| Manual sync | Click "Sync Now", or "Sync All Now" from the menu bar icon |
| Scheduled sync | Every 5 / 15 / 30 minutes or 1 / 3 / 12 hours, or daily at a fixed time |
| Preview changes | See exactly what will be copied or deleted before syncing; read-only |
| Multiple tasks | Manage several source → destination pairs independently |
| Launch at login | Stays in the menu bar and keeps syncing on schedule after the window is closed |
| Ignores system files | `.DS_Store`, `.Spotlight-V100`, `.fseventsd` and similar are skipped automatically |
| Only changed files | Uses size + modification time, with a 2.5-second tolerance for exFAT/FAT32 |
| Sync history | Time, result, data volume, failure reason and a per-file list of what was created, updated or deleted; details are not truncated (last 300 runs kept) |

### Safety by design

- **The destination folder must already exist.** FolderSync only creates the same-named
  subfolder inside it. If an external drive is not mounted, it will never create a
  directory on your local disk and write there.
- **Recursion guard:** destination inside source, source inside destination, or identical
  paths are all rejected.
- **Mirror deletions are guarded:** if the source scan finds no files at all, every delete
  is skipped with a warning, so an unreadable source cannot empty the destination.
- **Deletes go to the Trash first**, and only become permanent when the drive does not
  support the Trash.
- Copies are written to a temporary file and then atomically replaced, so a failure or
  power loss never leaves a half-written file.
- **Interruption guard:** 8 consecutive write failures are treated as a disconnected
  drive and the run stops.

---

## Requirements

- macOS 14 or later; Intel and Apple silicon are both supported.
- No additional software. The destination can be an external drive, a USB stick,
  another internal disk, or a network volume.

---

## Installation

1. Download `FolderSync-1.1.0.dmg` from [Releases](https://github.com/fangdc/folder-sync-app/releases/latest),
   open it, and drag **FolderSync.app** into the Applications folder.

2. The app is not signed with an Apple Developer certificate, so macOS blocks it the
   first time. Allow it once, using either method:

   **Option 1 (Terminal):** press ⌘Space, type `Terminal`, press Return, then run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/FolderSync.app
   ```

   If you get `Operation not permitted`, put `sudo` and a space in front of the command
   and enter your password again.

   **Option 2 (no Terminal):** double-click the app once, dismiss the "cannot be opened"
   dialog, then go to **System Settings → Privacy & Security**, scroll to **Security**,
   click **Open Anyway**, and confirm.

3. On first launch macOS asks for access to your Desktop, Documents, Downloads and
   removable volumes. Choose **Allow**.

> If you copy the DMG to someone else on a USB stick or over the local network, the file
> loses its quarantine flag, so they can skip step 2.

---

## Your first sync

1. Open the app and click **New Sync Task** in the top-left corner (the welcome screen
   appears on first launch and lets you create one right away).
2. **Source folder:** the folder on your Mac you want to sync out. Click **Choose Folder**.
3. **Destination folder:** the root of your external drive (or any target folder).
   This row shows the final path, e.g. `/Volumes/MyDrive/Desktop`.
4. Click **Preview Changes** to see what will be copied, then **Sync Now**.

If the source folder belongs to another app's container (for example a chat app's
message history), add FolderSync manually under **System Settings → Privacy & Security →
Full Disk Access**.

---

## Interface and shortcuts

| Item | Purpose |
| --- | --- |
| New Sync Task | Top of the sidebar; creates a task |
| Sync All Tasks | Bottom of the sidebar; runs every enabled task |
| Enable this task | Top of the detail view; pauses a task but keeps its settings |
| Preview Changes | Read-only list of files that would be copied or deleted |
| Sync Now | Starts the sync |
| View All Records | Opens the full sync history |
| Sync Details | Expands a record to list every file created, updated or deleted |

**Selecting multiple tasks:** hold `⌘` to add or remove tasks, hold `⇧` to select a
range; with several selected, right-click to "Sync Selected Tasks" or delete them all.

**Keyboard shortcuts** (when the main window is open):

| Shortcut | Action |
| --- | --- |
| `⌘R` | Sync all now |
| `⌘,` | Settings |
| `⌘0` | Open the main window |
| `⌘W` | Close the window |

---

## Sync modes

Switch under **Mode** in the detail view:

- **Incremental (default, recommended):** copies new and changed files only. Files
  deleted from the source stay in the destination.
- **Mirror:** adds, updates and deletes so the destination matches the source exactly.
  **Run Preview Changes first.**

In mirror mode, deleted files go to the Trash on disks that support it; exFAT drives,
common for external storage, do not, so files are deleted permanently.

## Automatic sync

Under **Frequency** in the detail view:

- **Manual only:** syncs only when you click a button.
- **Interval:** every 5 / 15 / 30 minutes or 1 / 3 / 12 hours.
- **Daily:** pick a time, either by typing it or with the stepper.

With **Launch at login** enabled in Settings, FolderSync stays in the menu bar after the
window is closed and keeps syncing on each task's schedule. The menu bar icon rotates
while a sync is running.

## Multiple tasks

- Each task is one source → destination pair; tasks do not affect each other.
- A task is always named after its source folder. The name cannot be changed, so the
  Mac and the drive always agree.
- Deleting a task asks for confirmation and removes only the task and its history;
  files that were already synced are left alone.

## Sync history

After each run, **Recent Records** on the task detail page shows its time, result and
data volume. Click **View All Records** to open the full history.

- On records with file changes, **Sync Details** on the right of the second line expands
  to list every file that was **created, updated or deleted**, with file sizes.
- When a folder is deleted, its subfolders and files are listed too; system junk such as
  `.DS_Store` is hidden.
- Renaming a folder is reported as a folder **modification**, not as new files; an empty
  folder rename also shows "Modified 1".
- Details are not truncated. The last 300 runs are kept; lists taller than 180 pt scroll
  inside the box.

---

## What it does to your computer

- The **source folder is read-only**: nothing in it is modified, moved or deleted.
- Files are written only inside `destination/source-folder-name/`; other contents of the
  destination are untouched.
- Modification times and permissions are preserved. The app does not use the network,
  upload anything, or send analytics.
- Data lives in:

  ```
  ~/Library/Application Support/FolderSync/
  ├── config.json     task configuration
  └── history.json    sync history (last 300 runs, with per-file details)
  ```

- With **Launch at login** enabled, a login item is written to:
  `~/Library/LaunchAgents/local.foldersync.autostart.plist`
- **To uninstall completely:** turn off Launch at login, delete
  `/Applications/FolderSync.app`, then delete `~/Library/Application Support/FolderSync/`.

## Known limitations

- One-way sync only (source → destination). No two-way merge and no conflict handling.
- Change detection uses size + modification time, not content hashes; a file with the
  same size and timestamp but different contents is not detected.
- Directory symlinks are not followed (the symlink itself is copied) to avoid cycles.
- Bundles such as `Photos Library.photoslibrary` are treated as ordinary folders and
  copied file by file; use Finder if you want to copy them as a whole.
- The app is ad-hoc signed and not notarized, so the first launch on another Mac needs
  the workaround described under Installation.
- When the menu bar is crowded, macOS hides new icons under `«`; hold `⌘` and drag to
  reorder them.
- **Preview Changes** lists at most the first 300 items; the actual sync is not limited
  by this display cap.
- Every change is saved per run. A first full sync of a very large folder can make
  `history.json` noticeably larger.
- Sync failures are listed in **Sync History**; more detailed runtime errors can be found
  in Console.app by searching for `FolderSync`.

---

## License

[MIT License](LICENSE), copyright holder: DACONG.

You may use, modify and redistribute it freely, including in commercial projects, as
long as the copyright and license notices are kept. The software is provided "as is",
without warranty of any kind. Syncing changes what is on your disks, so keep another
backup of important data.

macOS and Apple are trademarks of Apple Inc. This project is not affiliated with Apple Inc.

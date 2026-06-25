# LocalLibraryManager sample data

This directory is a **template** for the runtime sample-data
location. The actual import location is the app's sandbox:

```
~/Library/Developer/CoreSimulator/Devices/<simulator-udid>/data/Containers/Data/Application/<app-uuid>/Documents/AriaLibrary.sampleData/
```

(see `LocalLibraryManager.sampleDataDirectory` in
`Managers/LocalLibraryManager.swift`).

## How it works

On first launch (or whenever the app's `LocalLibraryManager` is
initialized and the sample-data directory contains files that are
not already in the library), `importSampleDataIfPresent()` scans
the directory and imports each audio file through the same path
as a normal user import (`importFile(at:)` — format validation,
security-scoped access, metadata extraction, the works).

The import is **idempotent**: re-running the app on the same
sample-data files does not duplicate them (each file's `fileName`
is matched against the current `tracks` set, and duplicates are
skipped).

Source files are **not deleted** after import — they remain in the
sample-data directory for re-import if the user removes a track
and wants it back.

## How to use it (simulator)

1. Find your simulator's app container:
   ```sh
   xcrun simctl get_app_container booted com.aria.music data
   ```
   (replace `com.aria.music` with the actual bundle ID).
2. Create the `AriaLibrary.sampleData/` subdirectory if it doesn't
   exist:
   ```sh
   mkdir -p "<container>/Documents/AriaLibrary.sampleData"
   ```
3. Copy audio files into it:
   ```sh
   cp ~/Music/sample.mp3 "<container>/Documents/AriaLibrary.sampleData/"
   ```
4. Launch (or relaunch) the app. The files appear in the Library
   tab on next launch.

## How to use it (device)

`UIFileSharingEnabled` is not currently set in
`Aria---Music-Browser-Info.plist`, so the app's Documents directory
is not exposed to the Files app. To add sample data on a real
device, either:

- Enable `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
  in the Info.plist (then the Documents directory shows up under
  "On My iPhone" → Aria in the Files app), or
- Use Xcode's Devices window → select the device → Aria →
  Download Container → drop the file into
  `AriaLibrary.sampleData/` → re-upload the container.

## Why this is gitignored

The directory structure is committed (via `.gitkeep` and this
README) so the convention is reproducible across clones, but the
actual audio files are user-supplied and never committed — they
bloat the repo and they may be licensed content you don't have
rights to redistribute.

The runtime location (`Documents/AriaLibrary.sampleData/`) is in
the app's sandbox and is never in git regardless.

## Removing this feature

To opt out, delete `importSampleDataIfPresent()` calls from
`LocalLibraryManager.init` and remove the `sampleDataDirectory`
property. The directory in the repo can stay (it'll just be dead
code) or be removed.

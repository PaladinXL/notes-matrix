# Troubleshooting

## `Operation not permitted` when listing project files

Grant terminal access to `Documents` in macOS:

1. System Settings -> Privacy & Security
2. Enable terminal app under `Files and Folders` and/or `Full Disk Access`
3. Restart terminal

## `Timed out while reading Notes`

1. Confirm macOS Automation permission for Notes.
2. Run quick test:

```bash
osascript -l JavaScript -e 'Application("Notes").name()'
```

3. Use fast export mode first (without `--with-attachments`).

If timeouts happen frequently, keep Notes app open during export and use
`--incremental` after first full export.

## Export is slow

Use fast mode:

```bash
notes-matrix export --output /path
```

Deep mode is slower but attempts full attachment extraction:

```bash
notes-matrix export --output /path --with-attachments
```

## Notes missing from custom folders

Re-run export with latest version. Folder mapping uses account/folder traversal
and note ID fallback.

If still missing, open an issue with:

- macOS version
- Note account type (iCloud, On My Mac, etc.)
- Expected folder path

## Export goes to `Unknown/Notes`

This means metadata mapping could not be resolved in that run.

Current versions include cache guards and automatic full-scan fallback, but if
you still see this, clear metadata cache and retry:

```bash
rm -f ~/Library/Caches/notes-matrix/metadata-folder-cache.json
```

Then run:

```bash
notes-matrix export --output /path --with-attachments --incremental
```

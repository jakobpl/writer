# mac_pastebin

A private notes app for macOS. Notes are stored locally and encrypted.

## Features

- Multiple notes
- Rich-text formatting
- Optimized, encrypted images
- Manual and automatic saving
- Manual and automatic locking
- Encrypted vault backups

More details are in [ENCRYPTION.md](ENCRYPTION.md).

## Build

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Add your Apple Team ID to `Config/Local.xcconfig`, then open `mac_pastebin.xcodeproj` in Xcode.

## Download

Requires macOS 26.5 or later. The download supports Apple Silicon and Intel Macs.

Download `mac_pastebin-macOS.zip` from [GitHub Releases](https://github.com/jakobpl/mac_pastebin/releases/latest/download/mac_pastebin-macOS.zip).

If macOS blocks the app, right-click `mac_pastebin.app`, select **Open**, then confirm.

You can also run:

```bash
xattr -cr /path/to/mac_pastebin.app
```

# Peekaboo

A macOS Quick Look extension that renders source code files with syntax highlighting, using your active VS Code theme.

Press Space on any code file in Finder and get a preview that actually looks like your editor — correct colors, correct font, your theme.

<video src="https://github.com/user-attachments/assets/e5e5f140-9228-453a-aea5-10983e9872f0" autoplay loop muted playsinline></video>

## Features

- Syntax highlighting powered by the same TextMate grammar engine VS Code uses
- Automatically picks up your active VS Code (or Antigravity) theme — change your theme in VS Code, hit Refresh, and the preview updates instantly
- Markdown rendering with GFM support and syntax-highlighted code blocks
- Works in both Quick Look panel and Finder column view

<video src="https://github.com/user-attachments/assets/14b17a9c-baf1-414d-9901-4a204ab453db" autoplay loop muted playsinline></video>

## Installation

Peekaboo is not notarized (no paid Apple Developer account), so macOS Gatekeeper will refuse to open it by default. Stripping the quarantine attribute tells Gatekeeper the app didn't come from the internet and lets it launch.

1. Download the latest `Peekaboo-v*.zip` from [Releases](../../releases) and unzip it.
2. Run these lines in Terminal. If you extracted somewhere other than `~/Downloads`, update the path in the first line:

   ```bash
   killall Peekaboo 2>/dev/null
   rm -rf /Applications/Peekaboo.app && mv ~/Downloads/Peekaboo.app /Applications/
   xattr -dr com.apple.quarantine /Applications/Peekaboo.app
   qlmanage -r && killall -HUP Finder
   ```

3. Press Space on any code file in Finder.

If previews don't appear, quit and reopen Finder, or run `qlmanage -r && killall -HUP Finder` again.

### Building from source

```bash
xcodebuild -project QuickLookCode/QuickLookCode.xcodeproj -scheme QuickLookCode -configuration Debug build
cp -R ~/Library/Developer/Xcode/DerivedData/QuickLookCode-*/Build/Products/Debug/Peekaboo.app /Applications/
qlmanage -r && killall -HUP Finder
```

To produce a distributable zip, run `scripts/package.sh`.

## A note

This started as a personal project to scratch my own itch — I wanted Quick Look previews that looked like my editor. I haven't tested it exhaustively across all edge cases and file types, so you may run into rough edges.

If you hit a bug, please [open an issue](../../issues) — I'm happy to take a look.
If you have an idea for something that would make this more useful for you, [open an issue](../../issues) for that too — I'm genuinely open to it.

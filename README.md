# Peekaboo

A macOS Quick Look extension that renders source code files with syntax highlighting, using your active VS Code theme.

Press Space on any code file in Finder and get a preview that actually looks like your editor — correct colors, correct font, your theme.

## Features

- Syntax highlighting powered by the same TextMate grammar engine VS Code uses
- Automatically picks up your active VS Code (or Antigravity) theme
- Markdown rendering with GFM support and syntax-highlighted code blocks
- Works in both Quick Look panel and Finder column view

## Installation

Build from source in Xcode, then copy the app to `/Applications/`:

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/QuickLookCode-*/Build/Products/Debug/QuickLookCode.app /Applications/
qlmanage -r
killall -HUP Finder
```

## A note

This started as a personal project to scratch my own itch — I wanted Quick Look previews that looked like my editor. I haven't tested it exhaustively across all edge cases and file types, so you may run into rough edges.

If you hit a bug, please [open an issue](../../issues) — I'm happy to take a look.
If you have an idea for something that would make this more useful for you, [open an issue](../../issues) for that too — I'm genuinely open to it.

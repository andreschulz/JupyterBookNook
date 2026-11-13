<p align="center">
  <img src="Sources/JupyterBookNook/Resources/AppIcon.png" alt="JupyterBookNook app icon" width="160">
</p>

<h1 align="center">JupyterBookNook</h1>

<p align="center"><strong>A native macOS editor for <a href="https://jupyterbook.org">Jupyter Book 2</a> projects written in MyST Markdown.</strong></p>

JupyterBookNook lets you write the pages of a Jupyter Book and also organise the book itself: chapters
and parts, `myst.yml`, bibliography, style, plugins, the live preview and HTML export. Adding,
moving or renaming a chapter updates `myst.yml` for you, so you only open the YAML when you want to.

> **About this project.** JupyterBookNook is a personal tool that I built for my own writing, and I
> share it because it might be useful to others. It was *vibe-coded* with
> [Claude](https://claude.ai) (Anthropic's AI assistant): the code was written by Claude in conversation
> with me, and tested by using the app, not reviewed line by line. Expect rough edges.
>
> **No warranty, no responsibility.** The software is provided as is, without warranty of any kind
> (see the [licence](LICENSE)). I take no responsibility for any damage or data loss caused by using it.
> It edits files in your book folders, including `myst.yml`, so keep your books under version control
> or make backups. Support and updates happen when I find the time.

## Features

- **MyST-aware editor.** Syntax highlighting for directives, roles, math, labels and front matter;
  spell checking on prose only; completion for directives, options, roles, labels, citation keys
  and file paths; problems (unknown labels, missing files, …) underlined while you type; folding,
  snippets with tab stops, find and replace, focus mode.
- **Live preview.** Editor, split and preview views. The preview is the real MyST site (`myst start`),
  so it looks exactly like the published book, with math, cross-references and citations. Editor and
  preview scroll together by section.
- **Book view.** An optional reading view of the page, with typeset headings, boxes, figures and
  math, that stays editable.
- **Organise the book from the sidebar.** New chapters (from templates) and parts, drag and drop,
  rename, remove. `myst.yml` is updated automatically as a minimal edit that keeps your comments,
  and every change can be undone.
- **Project settings without YAML.** Forms for title, authors, licence, theme, logo, numbering, math
  macros, exports and more, a bibliography editor for BibTeX files, a style editor for the website's
  fonts and colours, and a plugin manager.
- **Build and export.** Build with a clickable problem list, export the HTML site (optionally as a zip
  for GitHub Pages or any web server), and build PDF, Word and other documents that MyST supports.
- **Templates.** Project templates (lecture notes, thesis, course with exercises, …), page templates
  and snippets, all editable.
- **Your choice of MyST.** Use a private copy of Node.js and MyST that the app installs and manages,
  or your own installation (project `.venv`, `node_modules`, Homebrew, `npx`, …), per book or as the default.
- **Built-in documentation.** *Help › JupyterBookNook Documentation* opens a Jupyter Book that explains
  MyST syntax (every example as source and result) and the app.
- **Light and dark mode** with editable syntax colour themes, fonts and line spacing.

The complete list is in [docs/FEATURES.md](docs/FEATURES.md).

## Requirements

- macOS 14 (Sonoma) or later
- To build the app: Xcode 16 or later, or the Xcode 16 Command Line Tools (`xcode-select --install`)
- To preview and build books: [MyST](https://mystmd.org) (`mystmd`) or Jupyter Book 2. You don't
  have to install it yourself. *Settings › MyST › Install* puts a private Node.js and MyST into the
  app's Application Support folder (about 100 MB).
- Optional: `pdf2svg` or Poppler (`brew install pdf2svg`) to use PDF figures on the website

## Installation

There are no pre-built downloads. Build the app from source:

```sh
git clone https://github.com/andreschulz/JupyterBookNook.git
cd JupyterBookNook
Scripts/make-app.sh
```

This builds a release version and writes `dist/JupyterBookNook.app`. Drag it to your Applications folder.
The app is signed only for the Mac it was built on; it is not notarised.

To run it straight from the source folder instead:

```sh
swift run JupyterBookNook
```

Or open `Package.swift` in Xcode, choose the **JupyterBookNook** scheme and press ⌘R.

## Getting started

1. Start the app. On first launch, go to *Settings › MyST* (⌘,) and click **Install**, or choose an
   existing MyST / Jupyter Book installation.
2. Open a book with *Project › Open Project…* (⌘O): any folder with a `myst.yml`. To try the app, open
   `Examples/SampleBook` from this repository.
3. Or create a new book with *Project › New Project…* (⌥⌘N) from one of the templates.
4. Write in the editor and switch to *Split* (⌘2) for the live preview. Add chapters with ⇧⌘N,
   build with ⌘B and export the website with ⇧⌘E.

*Help › JupyterBookNook Documentation* explains the rest, and *Help › Welcome Tour* gives a short overview.

## Project layout

```
Package.swift
Sources/BookModel/        myst.yml model, minimal-edit YAML writer, undoable project operations, templates
Sources/MystSyntax/       MyST tokenizer (highlighting, spell-check ranges), outline, tables, math text
Sources/BuildService/     finding and running MyST, build-log parsing, preview server, managed install
Sources/ProjectIndex/     labels, citations and files of a book; completion items and diagnostics
Sources/JupyterBookNook/  the SwiftUI app (macOS only)
Scripts/                  make-app.sh (builds the .app) and make-icon.swift (builds the icon)
Examples/SampleBook/      small Jupyter Book 2 project for trying the app
Design/                   the app icon
docs/FEATURES.md          the complete feature list
```

## Feedback

Bug reports and ideas are welcome as [GitHub issues](https://github.com/andreschulz/JupyterBookNook/issues).
As this is a personal tool, I can't promise to act on every request.

## License

[MIT](LICENSE) © 2026 Andre Schulz

JupyterBookNook builds on [MyST Markdown](https://mystmd.org) and [Jupyter Book](https://jupyterbook.org)
and uses [Yams](https://github.com/jpsim/Yams) (MIT) to read YAML. It is an independent project and is
not affiliated with Project Jupyter, the Executable Books project or Anthropic.

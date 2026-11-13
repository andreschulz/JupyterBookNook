# JupyterBookNook — features in detail

The complete list of what the app does today. For an overview, installation and first steps, see the
[README](../README.md).

- **Open a book.** Choose a folder that contains `myst.yml`. The sidebar shows the table of contents
  (`project.toc`), with page titles taken from front matter or the first `#` heading. If the book has
  no `toc`, the order is inferred from the file names. Markdown files missing from the TOC appear
  separately, and TOC entries whose file is missing are flagged.
- **Edit pages in tabs.** The editor is an `NSTextView` with the find bar. Smart quotes, dashes and
  auto-correction are switched off so they don't change Markdown. ⌘S saves. Closing a tab or
  quitting the app saves too.
- **MyST highlighting.** Front matter, headings, directives with their options, admonitions coloured
  by type, code cells, math (`$…$`, `$$…$$`, `{math}`), roles, labels, links, comments, footnotes
  and substitutions. The page is rescanned on every keystroke.
- **Spell checking on prose only.** macOS spell checking skips code, math, roles, labels,
  directive options, paths and URLs. Admonition titles and link text are still checked.
- **Outline and breadcrumb.** The outline on the right (⌥⌘0) lists the page's headings with their
  labels and highlights the one containing the cursor; clicking one jumps there. The bar above the
  text shows the file, the current heading and the cursor's line and column.
- **New chapter / new part (⇧⌘N).** This creates the `.md` file and updates `myst.yml` automatically.
- **Organise the book from the sidebar.** Every action updates `myst.yml` for you:
  - drag a page or part onto a part to put it at the end of that part, or onto a page to put it before that page;
  - drag a file from *Not in table of contents* into the book, or right-click it and choose *Add to…*;
  - right-click for *Move Up*, *Move Down* and *Move To*;
  - *Rename…* changes a page's title (front matter or first heading) and optionally its file name or folder.
    Links, `{include}`s and figures that point to the page are updated in every page;
  - *Remove from Book* (or the Delete key) takes a page out of the table of contents and keeps the file.
    Removing a part keeps its chapters. *Move to Trash…* also moves the file to the Trash.
- **Minimal edits and undo.** Only the `toc` block of `myst.yml` is rewritten; every other line and comment stays
  as it is. ⌘Z undoes each action, files and `myst.yml` together, and ⇧⌘Z redoes it. Undo is refused
  if `myst.yml` or an affected page was edited since. The notice after each change has *Show Change*
  (a diff of `myst.yml`) and *Undo*. If `myst.yml` was changed in another editor, the app reloads it
  instead of overwriting it.

- **Completion.** Typing `{` in a fence offers directives; `{` in text offers roles; inside `{ref}`,
  `{numref}` or `{eq}` the book's labels (of the right kind, with title and page); inside `{cite}` or
  after `@` the keys of the bibliography; after `](`, in `{doc}` or as a figure/include argument the
  project's files; `#` in a link the headings and labels; `:` under a directive its options. The list
  opens by itself after those characters, Esc opens it anywhere, and it stays off in code and math.
  Choosing a directive also adds the matching closing fence on the line below.
- **Problems while editing.** The inspector lists the page's problems under the outline, and the
  text underlines them: unknown labels and citation keys, unknown directives and roles (plugins'
  names count as known; not checked while a plugin cannot be read), missing files, and labels defined twice in the book.
- **Find (⌘F, ⌥⌘F, ⌘G, ⇧⌘G, ⌘E)** in the editor.
- **Two kinds of settings.** *Project Settings* (⌥⌘,, sidebar › Project Settings) belong to the open book
  and are written to its `myst.yml`; the few the app keeps for a book (spelling language, running
  notebooks, which MyST installation) are marked there. *Settings* (⌘,) apply to all books: Editor,
  Templates, MyST.
- **Project settings (⌥⌘,, or *Project Settings* in the sidebar).** Forms for title, authors,
  licence, GitHub, bibliography, keywords, theme, logo and favicon, site layout, math macros,
  numbering, cell outputs and document exports, next to the table of contents and the live
  `myst.yml`. Each change is written about a second after typing stops, as a minimal edit: only the
  changed keys are rewritten, comments and key order stay. ⌘Z undoes it. *Open myst.yml as Text*
  covers everything else. Files not in the table of contents can be added or ignored.
- **Snippets (⌘T).** An overlay over the editor lists snippets (figure, table, equation, note,
  admonition, dropdown, tabs, cards, theorem, exercise, code cell, label) and page templates; type to
  filter, ↵ inserts at the cursor. `{{cursor:text}}` selects `text` after inserting, `{{2:text}}`,
  `{{3}}`, … are further stops that ⇥ / ⇧⇥ move between (Esc ends), `{{selection}}` wraps the selected
  text, and a snippet of several lines starts on its own line with the line's indentation.
- **Table assistant.** Every table in a page (pipe tables, also inside `{table}`, and `{list-table}`)
  has a pink “TA” circle at the right of its first line; *Edit › Table Assistant…* (⌃⌘T) opens it for
  the table at the cursor, or for a new table. A sheet shows the table as a grid: edit cells, add rows
  and columns, move them, delete them (after asking), align columns, switch between pipe and list
  table, set caption, label, numbering, header rows and class. *Apply* (⌘↩) writes the table back as
  one undo step, pipe tables in even columns; *Look of All Tables…* opens Style › Tables.
- **Templates (Settings › Templates, the same for all books).** Snippets and page templates are edited in place, built-in ones
  too (a change is saved as your own copy, which *Restore Built-in* removes). *Project › New Project* (⌥⌘N)
  sets up a folder you choose (new, empty, or with files already) as a project from *Blank project*,
  *Lecture notes*, *Thesis*, *Course with exercises* or *JupyterBookNook Documentation*, with the pages in `content/`, and adds the
  folders `content/`, `figs/`, `download/` and `plugins/` where missing; files already there are kept.
  A folder that already has a `myst.yml` only gets the missing folders. *New Chapter*
  offers the page templates. Your templates are plain files in
  `~/Library/Application Support/JupyterBookNook/Templates` (`Snippets/`, `Pages/`, `Books/<folder>`);
  templates an older version kept in a book's `.nook/templates/` can be moved there with one click.
  Placeholders `{{title}}`, `{{label}}`, `{{author}}`, `{{book}}`, `{{date}}`.
- **Export HTML site (⇧⌘E).** Output folder, base URL (for GitHub Pages), theme, strict mode and an
  optional zip, with progress and the log. *Build Documents* builds the PDF, Word, … documents: the
  book documents listed in `myst.yml`, and, with *Export pages separately*, each page's own documents.
  The Exports tab has one checkbox per format for all pages (on: every page, −: some pages; a click sets
  or removes it everywhere); the inspector edits the open page. A page can
  also offer files made elsewhere, such as slides, as downloads. Both are written into the page's
  front matter (`exports`, `downloads`). The Execution tab can run notebook code (`--execute`) in builds and the preview.
- **Bibliography (sidebar › Bibliography).** BibTeX files in the book are added to `myst.yml`
  automatically. The screen lists every entry with authors, title, year and key; double-click opens
  an edit dialog (type, key, fields). Saving rewrites just that entry in its `.bib` file; ⌘Z undoes it.
- **Plugins (sidebar › Project › Plugins).** The book's `project.plugins`: each card shows the plugin's
  name, file or URL, and the directives, roles and transforms it adds (read with Node.js, or from the
  source without it). Those names are completed and not reported as unknown. *New Plugin…* creates a
  working starter plugin in the plugins folder (a directive and a role) and opens it; *Add File…* copies a plugin
  into the plugins folder; *Add from URL…* asks you to confirm, because MyST runs the plugin in every build. A
  switch takes a plugin out of `myst.yml` and keeps it in the list to switch on again. All of it can be undone.
  Plugins you use in several books go into your plugin library (Settings › Plugins, or *Add to Your Plugin
  Library* on a card) and are added to a book from *Add Plugin › From Your Plugin Library*. The preview
  restarts by itself when plugins change.
- **PDFs and images** open in a tab for viewing: the preview shows them (PDFs with pages to scroll),
  the editor says they are not for editing. SVG files open as text.
- **Hide front matter and directive options** (Settings › Editor, or View › Folding): the YAML at the top
  of a page and the `:option:` lines of directives fold into one line; click ⋯ or move the cursor in to see them.
- **Style (sidebar › Project › Style).** Fonts, sizes and colours of the website, part by part (text,
  title, headings, links, code, boxes, captions, quotes, tables, site colours), with separate colours for
  dark mode. Changes are written to the book's stylesheet as you go and show in the preview next to the
  editor; the CSS files can be shown instead. Start from a built-in style, save your own for other books,
  or load the style of another book. CSS of your own stays in the file below the editor's part. The site's
  frame is there too: the site name in the top bar (instead of "Made with MyST"), the "Made with MyST" link
  under the table of contents (hide, restyle or replace it), previous/next links, a page footer and the outline.
- **Book view (⌥⌘B, Source | Book above the editor).** The page as it reads in the book: serif text in
  a centred column, real headings, the front matter's title, bold, italic, code and links without their
  markup, labels and comments hidden, admonitions and other directives as boxes, figures with their
  image, code as panels, math as typeset text, references as their target's title and citations as
  "(Author, Year)". The paragraph you edit shows its MyST, so everything stays
  editable; undo, spelling, completion and snippets work as in the source view.
- **Folders for new files.** *Project Settings › Folders for new files* sets where the app puts new
  files of the book: pages in `content/`, figures in `figs/`, downloads (PDFs, other files) in
  `download/` and plugins in `plugins/` by default; BibTeX and CSS files go into the book folder.
  Kept in `.jupyterbooknook.yml` in the book folder (MyST warns about unknown keys in `myst.yml`);
  existing files are never moved.
- **Files from Finder.** Drop pages, images, PDFs or `.bib` files on the sidebar: pages are copied into
  the pages folder and added to the table of contents where they land, images into the figures folder
  (listed under *Figures*), PDFs and other files into the downloads folder, BibTeX files into the
  bibliography. One undo step.
- **Figures and links in the editor.** Drop an image (from Finder or *Figures*) into a page to insert a
  `{figure}` with its caption selected; hold ⇧ for just `![](…)`. PNG, JPEG, SVG, GIF, WebP, TIFF and PDF
  work. For a PDF figure the app writes an SVG next to it (with `pdf2svg` or Poppler's `pdftocairo`,
  e.g. `brew install pdf2svg`) and refers to it as `name.*`, so the site shows the sharp SVG and LaTeX/PDF
  exports use the PDF. Without a converter MyST turns the PDF into PNG (needs ImageMagick and Ghostscript).
- **Dark mode for figures (Project settings › Site & theme).** *Invert SVG figures in dark mode* adds a
  small marked CSS rule to the book's stylesheet (`site.options.style`, `styles.css` if there is none):
  black line drawings turn light on the dark background, colours keep their hue. A figure with
  `:class: no-invert` stays as it is. New books from the templates have it on. Drop a page from the sidebar to
  insert a link. Paths are written relative to the page.
- **Changes made elsewhere.** The book folder is watched: pages edited in another app or by `git` reload
  in their tabs, new and deleted files show up in the sidebar. A tab with unsaved edits whose file
  changed gets a bar: keep your version or use the one on disk. A `myst.yml` that cannot be read shows
  the parser's message and line in a red bar, keeps the last table of contents and blocks structural
  changes until it is fixed; opened as text, `myst.yml` is highlighted as YAML.
- **Quick Open (⌘P) and command palette (⇧⌘P).** Find pages, labels, `myst.yml`, bibliographies and
  images by typing a few letters; ">" (or ⇧⌘P) runs any menu command.
- **Editor settings (⌘, › Editor).** Light / dark / system appearance, syntax colour themes, font, size,
  line height, line numbers, a limited, centred line width and the author new projects start with
  (empty unless set), with a live preview next to them. *Edit Colours…* sets a light and a dark colour
  for each kind of syntax (a *Custom* theme, started from a built-in one). *Save Settings…* /
  *Load Settings…* write and read them, colours included, as a JSON file; *Reset to Defaults*.
  **Focus mode (⇧⌘↩)** hides everything but the page and dims all but the current paragraph.
- **Folding.** Triangles left of the text fold directives and code cells to their first line (View ›
  Folding, ⌥⌘← / ⌥⌘→; with ⇧ for all).
- **Inspector forms.** With the cursor in a directive, the inspector shows its argument and options as fields
  (add, change, remove); *Page* edits the front matter (title, short title, label, date, keywords, …).
- **Documentation.** *Help › JupyterBookNook Documentation* (also on the welcome screen and in the palette)
  opens a project that explains MyST syntax (Part I, every example as source and result) and the app
  (Part II). It is created from the built-in template the first time, in
  `~/Library/Application Support/JupyterBookNook/Documentation`. Opening it brings it up to date with
  the app: pages you did not change are replaced, for pages you changed the app asks first
  (`.jupyterbooknook-docs.json` records what it wrote). *New Project* offers the same template for a
  fresh copy, which is not updated.
- **Welcome.** Recent projects on the welcome screen and in Project › Open Recent; a short tour of the main
  features (Help › Welcome Tour). The spelling language can be set per book (Project Settings › Project).
- **Paste images.** ⌘V with a screenshot or an image file on the clipboard saves it in the figures folder and
  inserts a `{figure}` (⇧⌘V: just the image).
- **Build (⌘B).** Runs `myst build --html`. The panel below the editor lists errors and warnings;
  clicking one opens its page at the line. The *Log* tab shows MyST's full output.
- **Editor, Split, Preview (⌘1, ⌘2, ⌘3).** The control in the toolbar shows the editor, the editor
  with the live preview beside it, or the preview alone.
- **Live preview.** `myst start` runs on free ports for as long as the book is open, so switching views
  is instant. While the preview is visible, a page is saved about 0.6 s after you stop typing; MyST
  rebuilds it and the site reloads itself, as it does when you run `myst start` by hand. The preview
  follows the open tab. The status bar shows the MyST version, the problem count and the preview state.
- **Sync by section (Split view).** Scrolling the editor scrolls the preview to the same section, and
  scrolling the preview scrolls the editor to that heading. Headings are paired by the ids MyST gives
  them (their label, or one derived from the text). Toggle it with the ⇄ button in the preview header
  or **View › Sync Editor and Preview**.
- **Export.** *Reveal HTML in Finder* and *Export as Zip…* build first. *Open Preview in Browser*.
- **MyST installation** (Settings, ⌘,). Automatic uses the book's `.venv` or `node_modules`, then the
  app's own installation, then `myst` or `jupyter-book` on your PATH. You can pick one, per book or as
  the default, or enter a command such as `npx mystmd`. *Install* puts a private Node.js and mystmd
  (about 100 MB) in Application Support; *Remove* deletes it.

Not yet: a real math engine for the book view, a curated plugin catalogue, publishing to GitHub Pages.

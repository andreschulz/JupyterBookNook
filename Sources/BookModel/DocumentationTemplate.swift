import Foundation

/// The built-in "JupyterBookNook Documentation" project: Part I explains MyST syntax (every
/// example shows its source and, below it, the result), Part II explains the app. It is also what
/// Help › JupyterBookNook Documentation and the welcome screen open.
extension TemplateLibrary {
    public static let documentationName = "JupyterBookNook Documentation"

    public static let documentation = ProjectTemplate(
        name: documentationName,
        summary: "Part I explains MyST syntax with examples, Part II how to use JupyterBookNook.",
        files: [
            ("styles.css", DarkFigures.block),
            ("myst.yml", DocumentationPages.config),
            ("references.bib", DocumentationPages.references),
            ("figs/workflow.svg", DocumentationPages.workflowSVG),
            ("intro.md", DocumentationPages.intro),
            ("syntax-text.md", DocumentationPages.syntaxText),
            ("syntax-directives.md", DocumentationPages.syntaxDirectives),
            ("syntax-figures-tables.md", DocumentationPages.syntaxFiguresTables),
            ("syntax-math.md", DocumentationPages.syntaxMath),
            ("syntax-references.md", DocumentationPages.syntaxReferences),
            ("syntax-configuration.md", DocumentationPages.syntaxConfiguration),
            ("nook-start.md", DocumentationPages.nookStart),
            ("nook-organise.md", DocumentationPages.nookOrganise),
            ("nook-writing.md", DocumentationPages.nookWriting),
            ("nook-preview.md", DocumentationPages.nookPreview),
            ("nook-project.md", DocumentationPages.nookProject),
            ("nook-settings.md", DocumentationPages.nookSettings),
        ],
        symbol: "book.pages"
    )
}

/// The pages of the documentation project. Placeholders (title, author, … in double braces) would
/// be filled in when the project is created, so the pages never spell them out.
enum DocumentationPages {
    static let config = #"""
    # The JupyterBookNook documentation. See https://mystmd.org/guide/frontmatter
    version: 1
    project:
      title: {{book}}
      authors:
        - JupyterBookNook
      license: CC-BY-4.0
      bibliography:
        - references.bib
      math:
        '\R': '\mathbb{R}'
        '\grad': '\nabla'
      toc:
        - file: intro.md
        - title: I · MyST Syntax
          children:
            - file: syntax-text.md
            - file: syntax-directives.md
            - file: syntax-figures-tables.md
            - file: syntax-math.md
            - file: syntax-references.md
            - file: syntax-configuration.md
        - title: II · JupyterBookNook
          children:
            - file: nook-start.md
            - file: nook-organise.md
            - file: nook-writing.md
            - file: nook-preview.md
            - file: nook-project.md
            - file: nook-settings.md
    site:
      template: book-theme
      options:
        style: styles.css

    """#

    static let references = #"""
    @book{knuth1984,
      author = {Donald E. Knuth},
      title = {The TeXbook},
      publisher = {Addison-Wesley},
      year = {1984}
    }

    @misc{mystmd2024,
      author = {{Executable Books}},
      title = {MyST Markdown Guide},
      year = {2024},
      url = {https://mystmd.org/guide}
    }

    """#

    static let workflowSVG = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 560 120" width="560" height="120" font-family="Helvetica, Arial, sans-serif" font-size="15">
      <rect x="10" y="30" width="140" height="60" rx="10" fill="none" stroke="black" stroke-width="2"/>
      <text x="80" y="66" text-anchor="middle">MyST pages</text>
      <rect x="210" y="30" width="140" height="60" rx="10" fill="none" stroke="black" stroke-width="2"/>
      <text x="280" y="66" text-anchor="middle">MyST build</text>
      <rect x="410" y="30" width="140" height="60" rx="10" fill="none" stroke="black" stroke-width="2"/>
      <text x="480" y="58" text-anchor="middle">Website,</text>
      <text x="480" y="78" text-anchor="middle">PDF, Word</text>
      <line x1="150" y1="60" x2="202" y2="60" stroke="black" stroke-width="2"/>
      <polygon points="210,60 198,54 198,66" fill="black"/>
      <line x1="350" y1="60" x2="402" y2="60" stroke="black" stroke-width="2"/>
      <polygon points="410,60 398,54 398,66" fill="black"/>
    </svg>

    """#

    static let intro = #"""
    (sec-welcome)=
    # Welcome

    This book explains two things:

    - **Part I · MyST Syntax** shows how pages of a Jupyter Book are written: text and structure,
      directives and roles, figures and tables, math, cross-references and citations, and the
      configuration in front matter and `myst.yml`.
    - **Part II · JupyterBookNook** shows how this app helps you write, organise, preview and publish
      such a book.

    :::{figure} ../figs/workflow.svg
    :label: fig-workflow
    :alt: MyST pages are built into a website, PDF or Word documents
    :width: 90%

    You write pages in MyST Markdown; MyST builds them into a website and documents.
    :::

    The documentation is a JupyterBookNook project itself, so you can read the source of every page
    in the editor and its result in the preview next to it (*Split*, ⌘2). Change anything you like and
    see what happens. When a new version of the app brings new documentation, the pages you did not
    change are updated; for pages you changed, the app asks first. *Project › New Project…* with the
    template *JupyterBookNook Documentation* gives you a fresh copy at any time.

    :::{tip}
    In Part I, every example shows its MyST source in a grey box first and the result right below it.
    Copy the source into a page of your own to start from it.
    :::

    ## Where to start

    - New to MyST? Start with {ref}`sec-text`, then {ref}`sec-directives`.
    - New to the app? Start with {ref}`sec-nook-start`.
    - Looking for a shortcut? See {ref}`sec-nook-shortcuts`.

    """#

    static let syntaxText = #"""
    (sec-text)=
    # Text and Structure

    MyST Markdown is Markdown, the plain-text format with `#` headings and `*emphasis*`, plus a few
    additions for books and papers {cite:p}`mystmd2024`. A page is a text file ending in `.md`.

    ## Headings

    A line starting with `#` is a heading; more `#` make lower levels. The first `#` heading of a page
    is its title (unless the front matter sets one, see {ref}`sec-configuration`).

    ````markdown
    ## A section
    ### A subsection
    ````

    Put a **label** on the line before a heading to refer to it from anywhere in the book
    ({ref}`sec-references`):

    ````markdown
    (sec-results)=
    ## Results
    ````

    ## Paragraphs and line breaks

    Lines that follow each other form one paragraph; a blank line starts the next one. So you can
    write one sentence per line, which makes changes easy to follow, and the reader still sees
    flowing text.

    ## Emphasis and inline code

    ````markdown
    Text can be *italic*, **bold** or `code`.
    ````

    Text can be *italic*, **bold** or `code`.

    ## Lists

    ````markdown
    - An item
    - Another item
      - A nested item (indented by two spaces)

    1. First
    2. Second
    ````

    - An item
    - Another item
      - A nested item (indented by two spaces)

    1. First
    2. Second

    ## Links

    ````markdown
    [MyST guide](https://mystmd.org/guide), <https://jupyterbook.org>,
    and [a page of this book](syntax-math.md).
    ````

    [MyST guide](https://mystmd.org/guide), <https://jupyterbook.org>,
    and [a page of this book](syntax-math.md).

    ## Quotes and rules

    ````markdown
    > A quotation starts with `>`.

    ---
    ````

    > A quotation starts with `>`.

    ---

    ## Footnotes

    ````markdown
    A claim that needs a note.[^source]

    [^source]: The note, shown at the end of the page.
    ````

    A claim that needs a note.[^source]

    [^source]: The note, shown at the end of the page.

    ## Small roles for text

    Roles are written `` {name}`content` `` ({ref}`sec-directives` explains them). A few format text:

    ````markdown
    H{sub}`2`O, x{sup}`2`, {abbr}`MyST (Markedly Structured Text)` and {kbd}`Cmd` + {kbd}`S`.
    ````

    H{sub}`2`O, x{sup}`2`, {abbr}`MyST (Markedly Structured Text)` and {kbd}`Cmd` + {kbd}`S`.

    ## Comments

    A line starting with `%` is a comment: it stays in the file and never shows in the book.

    ````markdown
    % TODO: add an example here
    ````

    % This line is a comment and is not shown.

    """#

    static let syntaxDirectives = #"""
    (sec-directives)=
    # Directives and Roles

    MyST adds two kinds of markup to Markdown: **directives** for blocks (a note, a figure, a table)
    and **roles** for pieces of text inside a line (a reference, a citation, inline math).

    ## Directives

    A directive starts with three colons (or backticks), its name in braces and an optional
    *argument*. Then come *options* (`:name: value`), a blank line and the *body*. Three colons close it.

    ````markdown
    :::{note} An optional title
    :class: dropdown

    The body: ordinary MyST, with **formatting**, lists, math and more.
    :::
    ````

    :::{note} An optional title
    :class: dropdown

    The body: ordinary MyST, with **formatting**, lists, math and more.
    :::

    To put a directive inside another one, give the outer one more colons:

    ````markdown
    ::::{important}
    :::{tip}
    A tip inside an important box.
    :::
    ::::
    ````

    ::::{important}
    :::{tip}
    A tip inside an important box.
    :::
    ::::

    ## Admonitions

    Admonitions are coloured boxes. Each type has its own colour, in the book and in the editor.

    ````markdown
    :::{note}
    A note.
    :::
    :::{tip}
    A tip.
    :::
    :::{warning}
    A warning.
    :::
    :::{danger}
    Danger.
    :::
    :::{admonition} Any title you like
    A box with your own title.
    :::
    ````

    :::{note}
    A note.
    :::
    :::{tip}
    A tip.
    :::
    :::{warning}
    A warning.
    :::
    :::{danger}
    Danger.
    :::
    :::{admonition} Any title you like
    A box with your own title.
    :::

    Further types: `important`, `hint`, `caution`, `attention`, `error` and `seealso`.

    ## Dropdowns, tabs and cards

    ````markdown
    :::{dropdown} Click to open
    Hidden until the reader opens it, e.g. for a solution.
    :::

    ::::{tab-set}
    :::{tab-item} Python
    `print("hello")`
    :::
    :::{tab-item} JavaScript
    `console.log("hello")`
    :::
    ::::

    :::{card} A card
    Cards group a short piece of content.
    :::
    ````

    :::{dropdown} Click to open
    Hidden until the reader opens it, e.g. for a solution.
    :::

    ::::{tab-set}
    :::{tab-item} Python
    `print("hello")`
    :::
    :::{tab-item} JavaScript
    `console.log("hello")`
    :::
    ::::

    :::{card} A card
    Cards group a short piece of content.
    :::

    ## Code

    A code block starts and ends with three backticks; the language after the opening ones colours it.
    The `{code}` directive adds options such as a caption and line numbers.

    `````markdown
    ```python
    def step(x, rate):
        return x - rate * grad(x)
    ```

    ```{code} python
    :caption: One step of gradient descent
    :linenos:
    def step(x, rate):
        return x - rate * grad(x)
    ```
    `````

    ```python
    def step(x, rate):
        return x - rate * grad(x)
    ```

    ```{code} python
    :caption: One step of gradient descent
    :linenos:
    def step(x, rate):
        return x - rate * grad(x)
    ```

    To show MyST source itself, as this book does, use more backticks for the outer block than for
    anything inside it.

    ## Roles

    A role is a name in braces followed directly by its content in backticks:

    ````markdown
    See {ref}`sec-math` for {math}`e^{i\pi} + 1 = 0`.
    ````

    See {ref}`sec-math` for {math}`e^{i\pi} + 1 = 0`.

    The roles you will use most are `{ref}`, `{numref}` and `{eq}` for cross-references, `{cite}` for
    citations ({ref}`sec-references`) and `{math}` for inline math ({ref}`sec-math`).

    """#

    static let syntaxFiguresTables = #"""
    (sec-figures-tables)=
    # Figures and Tables

    ## Figures

    A figure is an image with a caption, a label to refer to it, and options for its size and the text
    that describes it to screen readers. The path is relative to the page.

    ````markdown
    :::{figure} ../figs/workflow.svg
    :label: fig-example
    :alt: Three boxes connected by arrows
    :width: 70%

    The caption, with *formatting* if you like.
    :::

    {numref}`fig-example` shows the workflow.
    ````

    :::{figure} ../figs/workflow.svg
    :label: fig-example
    :alt: Three boxes connected by arrows
    :width: 70%

    The caption, with *formatting* if you like.
    :::

    {numref}`fig-example` shows the workflow.

    A plain image without caption or number is written `![description](../figs/workflow.svg)`.

    ## Pipe tables

    Columns are separated by `|`; the line of dashes below the header can align columns with colons.

    ````markdown
    | Method   | Steps | Loss |
    |:---------|------:|:----:|
    | Gradient |  1000 | 0.31 |
    | Newton   |    12 | 0.30 |
    ````

    | Method   | Steps | Loss |
    |:---------|------:|:----:|
    | Gradient |  1000 | 0.31 |
    | Newton   |    12 | 0.30 |

    ## Tables with caption and label

    Wrap a pipe table in `{table}` to give it a caption and a label. Leave a blank line before the
    closing colons.

    ````markdown
    :::{table} Two methods compared
    :label: tbl-methods

    | Method   | Steps |
    |----------|------:|
    | Gradient |  1000 |
    | Newton   |    12 |

    :::

    {numref}`tbl-methods` compares them.
    ````

    :::{table} Two methods compared
    :label: tbl-methods

    | Method   | Steps |
    |----------|------:|
    | Gradient |  1000 |
    | Newton   |    12 |

    :::

    {numref}`tbl-methods` compares them.

    ## List tables

    In a list table each row is a list item, so cells can hold several lines, lists or math.

    ````markdown
    :::{list-table} Symbols
    :header-rows: 1
    :label: tbl-symbols

    * - Symbol
      - Meaning
    * - $\eta$
      - The step size, a small positive number
    * - $\grad f$
      - The gradient of $f$
    :::
    ````

    :::{list-table} Symbols
    :header-rows: 1
    :label: tbl-symbols

    * - Symbol
      - Meaning
    * - $\eta$
      - The step size, a small positive number
    * - $\grad f$
      - The gradient of $f$
    :::

    :::{tip}
    In JupyterBookNook every table has a pink **TA** circle at the end of its first line: it opens the
    table assistant, where you edit cells, rows and columns in a grid ({ref}`sec-nook-writing`).
    :::

    """#

    static let syntaxMath = #"""
    (sec-math)=
    # Math

    Math is written in LaTeX notation {cite:p}`knuth1984` and typeset in the book.

    ## Inline math

    ````markdown
    The update is $x_{k+1} = x_k - \eta \grad f(x_k)$ for all $x \in \R^n$.
    ````

    The update is $x_{k+1} = x_k - \eta \grad f(x_k)$ for all $x \in \R^n$.

    `\R` and `\grad` are *macros* of this book: `myst.yml` defines them under `project.math`
    ({ref}`sec-configuration`).

    ## Display math

    Two dollar signs on lines of their own make an equation on its own line. A label in parentheses
    after the closing dollars numbers it.

    ````markdown
    $$
    f(x) = \frac{1}{2} \lVert A x - b \rVert^2
    $$ (eq-least-squares)

    Equation {eq}`eq-least-squares` is a least-squares problem.
    ````

    $$
    f(x) = \frac{1}{2} \lVert A x - b \rVert^2
    $$ (eq-least-squares)

    Equation {eq}`eq-least-squares` is a least-squares problem.

    ## The math directive

    The `{math}` directive does the same with a `:label:` option; inside it, `aligned` lines up several
    lines at the `&`.

    ````markdown
    :::{math}
    :label: eq-gradient
    \begin{aligned}
    \grad f(x) &= A^\top (A x - b) \\
               &= A^\top A x - A^\top b
    \end{aligned}
    :::

    The gradient {eq}`eq-gradient` vanishes at the minimum.
    ````

    :::{math}
    :label: eq-gradient
    \begin{aligned}
    \grad f(x) &= A^\top (A x - b) \\
               &= A^\top A x - A^\top b
    \end{aligned}
    :::

    The gradient {eq}`eq-gradient` vanishes at the minimum.

    """#

    static let syntaxReferences = #"""
    (sec-references)=
    # Cross-references and Citations

    ## Labels

    A label names a place to refer to: `(name)=` on the line before a heading, or the `:label:` option
    of a figure, table or equation. Labels are unique in the whole book. Common prefixes keep them
    apart: `sec-` for sections, `fig-` for figures, `tbl-` for tables, `eq-` for equations.

    ## Referring to labels

    ````markdown
    - {ref}`sec-math` uses the section's title as the link text.
    - {ref}`the math chapter <sec-math>` uses your own text.
    - {numref}`fig-workflow` and {numref}`tbl-methods` show the number.
    - {numref}`Fig. %s <fig-workflow>` sets the text around the number.
    - Equation {eq}`eq-least-squares` gives the equation's number.
    - [A Markdown link](#sec-directives) works too.
    ````

    - {ref}`sec-math` uses the section's title as the link text.
    - {ref}`the math chapter <sec-math>` uses your own text.
    - {numref}`fig-workflow` and {numref}`tbl-methods` show the number.
    - {numref}`Fig. %s <fig-workflow>` sets the text around the number.
    - Equation {eq}`eq-least-squares` gives the equation's number.
    - [A Markdown link](#sec-directives) works too.

    ## Citations

    Citations refer to entries of a BibTeX file listed under `project.bibliography` in `myst.yml`
    (here `references.bib`). The reference list is added at the end of the page.

    ````markdown
    - {cite:t}`knuth1984` describes TeX. (textual)
    - TeX typesets math well {cite:p}`knuth1984`. (in parentheses)
    - Several at once {cite:p}`knuth1984; mystmd2024`.
    - Short form: @knuth1984.
    ````

    - {cite:t}`knuth1984` describes TeX. (textual)
    - TeX typesets math well {cite:p}`knuth1984`. (in parentheses)
    - Several at once {cite:p}`knuth1984; mystmd2024`.
    - Short form: @knuth1984.

    :::{tip}
    In JupyterBookNook, typing `{ref}` or `{cite}` offers the book's labels and citation keys, and
    unknown ones are underlined ({ref}`sec-nook-writing`).
    :::

    """#

    static let syntaxConfiguration = #"""
    (sec-configuration)=
    # Front Matter and myst.yml

    ## Front matter

    A page can start with YAML between two `---` lines: its *front matter*. It sets the page's title
    and other information MyST uses.

    ````yaml
    ---
    title: Gradient Descent
    short_title: Descent
    label: sec-descent
    date: 2026-10-30
    keywords: optimisation, gradient
    numbering:
      heading_2: true
    exports:
      - format: pdf
    downloads:
      - url: ../download/slides.pdf
        title: Slides (PDF)
    ---
    ````

    - `title` replaces the first heading as the page's title; `short_title` is used in the navigation.
    - `numbering` switches numbers for headings, figures, tables and equations on or off for this page.
    - `exports` lists documents MyST builds from the page (PDF, Word, LaTeX, …).
    - `downloads` offers files, such as slides made elsewhere, in the page's download menu (the icon
      at the top right of the page). Paths are relative to the page.

    ## myst.yml

    `myst.yml` in the book folder describes the whole book. This book's file looks like this:

    ````yaml
    version: 1
    project:
      title: JupyterBookNook Documentation
      authors:
        - JupyterBookNook
      license: CC-BY-4.0
      bibliography:
        - references.bib
      math:
        '\R': '\mathbb{R}'
      toc:
        - file: content/intro.md
        - title: I · MyST Syntax
          children:
            - file: content/syntax-text.md
    site:
      template: book-theme
      options:
        style: styles.css
    ````

    - `project` holds what belongs to the content: title, authors, licence, the bibliography, math
      macros, numbering, exports, plugins and the table of contents (`toc`).
    - In `toc`, `file:` adds a page, `title:` with `children:` a part, and `pattern: chapters/*.md`
      adds every file that matches.
    - `site` holds what belongs to the website: the theme (`book-theme` or `article-theme`), a
      stylesheet, a logo and layout options.

    :::{note}
    You rarely need to edit `myst.yml` by hand in JupyterBookNook: the sidebar writes the table of
    contents and *Project Settings* writes the rest ({ref}`sec-nook-project`).
    :::

    """#
}

extension DocumentationPages {
    static let nookStart = #"""
    (sec-nook-start)=
    # Getting Started

    JupyterBookNook is a Mac app for writing Jupyter Book 2 projects in MyST Markdown. It shows your
    pages as text with colours for the markup, the book as it will look next to them, and keeps
    `myst.yml` up to date while you organise the book.

    ## Projects

    A project (a book) is a folder with a `myst.yml`. Everything happens in the **Project** menu:

    - *New Project…* (⌥⌘N) sets up a folder as a project. Choose a new folder, an empty one, or one with
      files already: the template's files are added (pages in `content/`) without overwriting anything,
      and the folders `content/`, `figs/`, `download/` and `plugins/` are added where missing. A folder
      that already has a `myst.yml` only gets the missing folders.
    - *Open Project…* (⌘O) opens a folder with a `myst.yml`; *Open Recent* lists the last ones.

    Without an open project, the welcome screen offers the same, the recent projects and this
    documentation.

    ## The window

    :::{list-table}
    :header-rows: 1

    * - Area
      - What it does
    * - Sidebar (left)
      - The table of contents, files not in it, figures, and the project's settings, bibliography,
        plugins and style ({ref}`sec-nook-organise`).
    * - Tabs and editor (middle)
      - The open pages as MyST text ({ref}`sec-nook-writing`).
    * - Preview
      - The book as MyST builds it, updated while you type ({ref}`sec-nook-preview`).
    * - Inspector (right, ⌥⌘0)
      - The page's outline, the directive at the cursor, the page's front matter, exports and problems.
    * - Status bar and build panel (bottom)
      - The MyST version, the number of problems, the preview's state; ⇧⌘Y shows build messages.
    :::

    The control in the toolbar switches between *Editor* (⌘1), *Split* (⌘2, editor and preview side by
    side) and *Preview* (⌘3).

    ## MyST

    The preview and builds use MyST (`mystmd`). JupyterBookNook uses the book's own installation (in
    `.venv` or `node_modules`) if there is one, then its own copy, then one on your `PATH`.
    *Settings › MyST* can install a private copy (about 100 MB) with one click ({ref}`sec-nook-settings`).

    ## Saving

    Pages are saved with ⌘S, when a tab is closed, when the app quits, and — while the preview is
    visible — about half a second after you stop typing, so the preview follows. Every change the app
    makes to files can be undone with ⌘Z.

    """#

    static let nookOrganise = #"""
    (sec-nook-organise)=
    # Organising a Book

    The sidebar shows the book as readers see it: the table of contents from `myst.yml`, with each
    page's title. Where a file lies in the folder does not matter for the order.

    ## Chapters and parts

    - *Project › New Chapter…* (⇧⌘N) creates a page (from a page template if you like) in the pages
      folder and adds it to the table of contents. *New Part…* adds a part.
    - Drag a page or part onto a part to move it to the end of that part, or onto a page to put it
      before that page. Right-click for *Move Up*, *Move Down* and *Move To*.
    - *Rename…* changes a page's title and, if you like, its file name or folder. Links, includes and
      figures pointing to the page are updated in every page.
    - *Remove from Book* (Delete) takes a page out of the table of contents and keeps the file;
      *Move to Trash…* also moves the file to the Trash. Removing a part keeps its chapters.

    Every action rewrites only the `toc` part of `myst.yml`; comments and all other lines stay. The
    notice after each change offers *Show Change* and *Undo*.

    ## Other files

    - **Not in table of contents** lists pages that exist but are not in the book; drag one into the
      book, or right-click to add or ignore it.
    - **Figures** lists the book's images; drag one into a page to insert a figure.
    - Files dragged from Finder onto the sidebar are copied into the book: pages into the pages folder
      (and into the table of contents where you drop them), images into the figures folder, PDFs and
      other files into the downloads folder, BibTeX files into the book folder and the bibliography.

    ## Folders for new files

    *Project Settings › Project › Folders for new files* sets where new files go. The defaults are
    `content/` for pages, `figs/` for figures, `download/` for downloads and `plugins/` for plugins;
    an empty field means the book folder itself. The setting is kept in `.jupyterbooknook.yml` in the
    book folder (MyST would warn about unknown keys in `myst.yml`). Existing files are never moved.

    ## Changes made elsewhere

    The folder is watched: pages edited in another app or changed by `git` reload in their tabs, and
    new or deleted files appear in the sidebar. If a tab has unsaved edits and its file changed on
    disk, a bar asks whether to keep your version or use the one on disk.

    """#

    static let nookWriting = #"""
    (sec-nook-writing)=
    # Writing

    ## The editor

    The editor colours MyST as you type: headings, directives and their options, admonitions by type,
    roles, math, code, links, labels, comments and front matter. Smart quotes and automatic
    corrections are off, so they never change your Markdown. Spelling is checked in prose only, not
    in code, math, labels, options or paths.

    The bar above the text shows the file, the heading at the cursor, the line and column, and a
    *Source | Book* switch for the book view.

    ## Completion

    The list of suggestions opens by itself where a name usually follows, and Esc opens it anywhere:

    - after `{` on a fence line: directives (choosing one also adds the closing fence);
    - after `{` in text: roles;
    - inside `{ref}`, `{numref}` or `{eq}`: the book's labels, with title and page;
    - inside `{cite}` or after `@`: the keys of the bibliography;
    - after `](`, in `{doc}` or as a figure path: the book's files;
    - after `:` below a directive: its options.

    ## Snippets and templates

    ⌘T lists snippets (figure, table, equation, note, dropdown, tabs, theorem, exercise, code cell, …)
    and page templates; type to filter and press ↩ to insert. After inserting, ⇥ and ⇧⇥ move between
    the places to fill in, and Esc ends that. *Settings › Templates* edits them and adds your own.

    ## Tables

    Every table has a pink **TA** circle at the end of its first line. It opens the table assistant
    (also *Edit › Table Assistant…*, ⌃⌘T, which creates a new table when the cursor is not in one):
    edit cells in a grid, add, move and delete rows and columns, align columns, switch between pipe
    and list table, and set caption, label and header rows. *Apply* (⌘↩) writes the table back in
    one undo step.

    ## Figures and images

    Drop an image from Finder or from the sidebar's *Figures* into a page to insert a `{figure}` with
    its caption selected; hold ⇧ for just the image. ⌘V with a screenshot on the clipboard saves it in
    the figures folder and inserts a figure (⇧⌘V: just the image). Other files dropped into a page are
    copied into the downloads folder and linked. Paths are written relative to the page.

    ## Folding and hiding

    Triangles left of the text fold directives and code cells (⌥⌘← and ⌥⌘→, with ⇧ for all).
    *Settings › Editor* can hide the front matter and directive options in one line; the inspector still
    shows and edits them.

    ## Book view and focus mode

    - **Book view** (⌥⌘B) shows the page as it reads in the book: real headings, boxes for admonitions,
      figures with their images, math typeset, references as their targets' titles. The paragraph you
      edit shows its MyST, so everything stays editable.
    - **Focus mode** (⇧⌘↩) hides everything but the page and dims all but the current paragraph.

    ## Finding things

    - ⌘F, ⌥⌘F (replace), ⌘G and ⇧⌘G find in the page.
    - ⌘P (*Quick Open*) finds pages, labels, `myst.yml`, bibliographies and images by a few letters.
    - ⇧⌘P (*Command Palette*) runs any command by name.

    ## Inspector

    The inspector (⌥⌘0) lists the page's headings (click one to jump there), shows the directive at
    the cursor as fields for its argument and options, edits the page's front matter (title, label,
    date, keywords, …), its exports and downloads, and lists **problems**: unknown labels, citation
    keys, directives and roles, missing files and labels used twice. Problems are underlined in the
    text too.

    """#

    static let nookPreview = #"""
    (sec-nook-preview)=
    # Preview, Build and Export

    ## Live preview

    While a project is open, MyST runs in the background (`myst start`), so the preview is there at
    once. While the preview is visible, a page is saved shortly after you stop typing; MyST rebuilds it
    and the preview reloads. The preview follows the open tab; PDFs and images open in it for viewing.

    - **Scroll sync**: in *Split*, scrolling the editor scrolls the preview to the same place and the
      other way round. The ⇄ button in the preview's header switches it on and off.
    - **Selections**: text selected in the preview is marked in the editor, and text selected in the
      editor is marked in the preview.

    ## Build

    *Book › Build* (⌘B) runs `myst build --html`. The build panel (⇧⌘Y) lists errors and warnings;
    click one to open its page at the line. The *Log* tab shows MyST's full output.

    ## Export

    - *Export HTML Site…* (⇧⌘E) builds the website into a folder of your choice, with a base URL (for
      GitHub Pages), the theme, strict mode and an optional zip.
    - *Build Documents* builds the PDF, Word and other documents listed in `myst.yml`, and each page's
      own documents when pages export separately.
    - A page's documents and downloads are set in the inspector under *Exports*; *Project Settings ›
      Exports* sets formats for all pages at once.
    - *Reveal HTML in Finder* and *Export as Zip…* build first; *Open Preview in Browser* shows the
      preview in your browser.

    ## Running notebooks

    *Project Settings › Execution* can run the code of notebooks and code cells during builds and in
    the preview.

    """#

    static let nookProject = #"""
    (sec-nook-project)=
    # Project Settings, Style and Plugins

    ## Project Settings

    *Project › Project Settings…* (⌥⌘,) has forms for everything in `myst.yml`: title, authors,
    licence, bibliography, keywords, theme, logo, site layout, math macros, numbering, notebook
    outputs and exports, next to the table of contents and the live `myst.yml`. Each change is written
    as a small edit: only the changed keys, comments and order stay. ⌘Z undoes it. *Open myst.yml as
    Text* covers everything else. A few settings the app keeps for itself (spelling language, folders
    for new files) are marked as such.

    ## Bibliography

    *Bibliography* in the sidebar lists every entry of the book's BibTeX files with authors, title,
    year and key. Double-click an entry to edit it; only that entry changes in its file. BibTeX files
    in the book are added to `myst.yml` automatically.

    ## Style

    *Style* in the sidebar sets the website's fonts, sizes and colours part by part (text, headings,
    links, code, boxes, captions, tables, site colours), with separate colours for dark mode. Changes
    go into the book's stylesheet and show in the preview at once. Start from a built-in style, save
    your own for other books, or load the style of another book. Your own CSS below the style
    editor's part stays as it is. The site's frame is set there too: the name in the top bar, the
    "Made with MyST" link, previous/next links, a page footer and the outline.

    *Project Settings › Site & theme › Invert SVG figures in dark mode* turns black line drawings light
    on the dark background; a figure with `:class: no-invert` stays as it is.

    ## Plugins

    *Plugins* in the sidebar lists the book's MyST plugins with the directives, roles and transforms
    each adds; the editor completes those names and does not report them as unknown. *New Plugin…*
    creates a working starter plugin in the plugins folder, *Add File…* copies one in, *Add from URL…*
    asks first, because MyST runs plugins in every build. Plugins you use in several books go into your
    plugin library (*Settings › Plugins*). The preview restarts by itself when plugins change.

    """#

    static let nookSettings = #"""
    (sec-nook-settings)=
    # Settings and Shortcuts

    ## Settings for all projects

    *JupyterBookNook › Settings…* (⌘,) applies to every project:

    - **Editor**: the author new projects start with, light, dark or system appearance, syntax
      colours, font, size, line height, line numbers, fold markers, hiding front matter and directive
      options, a limited line width and focus mode, with a live preview next to them.
      *Edit Colours…* sets a light and a dark colour for each kind of syntax. *Save Settings…* and
      *Load Settings…* write and read all of it as a file; *Reset to Defaults* goes back to the start.
    - **Templates**: snippets, page templates and your own project templates.
    - **Plugins**: your plugin library.
    - **MyST**: which MyST installation to use, per project or as the default, and installing the app's
      own copy.

    (sec-nook-shortcuts)=
    ## Keyboard shortcuts

    :::{table} Keyboard shortcuts
    :label: tbl-shortcuts

    | Action                        | Shortcut |
    |-------------------------------|----------|
    | New project                   | ⌥⌘N      |
    | Open project                  | ⌘O       |
    | New chapter                   | ⇧⌘N      |
    | Project settings              | ⌥⌘,      |
    | Settings for all projects     | ⌘,       |
    | Save                          | ⌘S       |
    | Close tab                     | ⌘W       |
    | Previous / next tab           | ⇧⌘[ / ⇧⌘] |
    | Insert snippet                | ⌘T       |
    | Table assistant               | ⌃⌘T      |
    | Paste image only              | ⇧⌘V      |
    | Find / replace                | ⌘F / ⌥⌘F |
    | Find next / previous          | ⌘G / ⇧⌘G |
    | Quick open                    | ⌘P       |
    | Command palette               | ⇧⌘P      |
    | Editor / split / preview      | ⌘1 / ⌘2 / ⌘3 |
    | Book view                     | ⌥⌘B      |
    | Focus mode                    | ⇧⌘↩      |
    | Show or hide the inspector    | ⌥⌘0      |
    | Fold / unfold                 | ⌥⌘← / ⌥⌘→ |
    | Fold all / unfold all         | ⇧⌥⌘← / ⇧⌥⌘→ |
    | Build                         | ⌘B       |
    | Show build panel              | ⇧⌘Y      |
    | Export HTML site              | ⇧⌘E      |
    | Open the completion list      | Esc      |

    :::

    """#
}

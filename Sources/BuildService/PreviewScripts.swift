import Foundation

/// JavaScript injected into the preview page.
public enum PreviewScripts {
    /// Replaces the theme's live reload, which does a full `window.location.reload()` on every
    /// change and makes the preview flash and jump, with an in-place refresh: a `popstate` to the
    /// current URL makes the theme's router (Remix) re-run its loaders and redraw the page, keeping
    /// the scroll position. Falls back to a full reload if the page has no router state.
    /// Checked against the book theme of mystmd 1.11 in headless Chrome: the content updates,
    /// the scroll position stays, and no page load happens.
    public static func liveRefresh(contentPort: Int) -> String {
        """
        (function () {
          if (window.top !== window) return;
          // The theme does not open its own live-reload connection when this is set.
          window.mystLiveReloadConnected = true;
          var pending = null;
          function refresh() {
            var state = history.state;
            if (state && typeof state === 'object' && 'idx' in state) {
              window.dispatchEvent(new PopStateEvent('popstate', { state: state }));
            } else {
              window.location.reload();
            }
          }
          function connect() {
            var socket = new WebSocket('ws://' + location.hostname + ':\(contentPort)/socket');
            socket.onmessage = function (event) {
              var message;
              try { message = JSON.parse(event.data); } catch (e) { return; }
              if (message.type !== 'RELOAD') return;
              // Several pages may be rebuilt at once; refresh once.
              clearTimeout(pending);
              pending = setTimeout(refresh, 60);
            };
            socket.onclose = function () { setTimeout(connect, 1000); };
          }
          connect();
        })();
        """
    }

    /// The name of the message handler the scroll-sync script posts to.
    /// Loads the book's stylesheet (`myst-theme.css`, which holds `site.options.style`) again
    /// without reloading the page: a new link is added, and the old one removed once it has loaded,
    /// so the page does not flash.
    public static let reloadStylesheet = """
    (function () {
      document.querySelectorAll('link[rel="stylesheet"][href*="myst-theme.css"]').forEach(function (old) {
        var link = old.cloneNode();
        var url = new URL(old.href, location.href);
        url.searchParams.set('nook', Date.now());
        link.href = url.toString();
        link.onload = function () { old.remove(); };
        old.after(link);
      });
    })();
    """

    public static let syncHandlerName = "nookSync"

    /// Scroll sync by source line, with sections as the fallback.
    ///
    /// MyST serves each page's syntax tree next to it (`/<slug>.json`, `/index.json` for the
    /// start page) with source lines for its blocks. The script matches headings, paragraphs,
    /// code, display math and tables to the rendered elements by their text, in order, and then
    /// knows for every matched element which lines of the file it shows. Positions between them
    /// are interpolated, so the sync follows paragraph by paragraph.
    ///
    /// Posts `{type: "headings", items, initial}` when the page's headings are known or change,
    /// `{type: "anchors", count, lines}` when the matching changed, and `{type: "scroll", index,
    /// line, end}` while the page scrolls: the heading at the top (-1 above the first), the source
    /// line at the top (fractional; null without a match) and how far into its last screenful the
    /// page is (`end`, 0…1). `window.__nookScrollToLine(line, heading, animated, end)` scrolls to a
    /// source line, or to the heading when there is no match; `end` moves the target that share
    /// of the way to the bottom, so both sides reach their ends together.
    ///
    /// Selections: `{type: "selection", text, start, end}` when the reader selects text (the source
    /// lines it spans, interpolated like the scroll position; text "" when the selection is gone).
    /// `window.__nookHighlight(start, end, text)` marks text selected in the editor: the first
    /// occurrence of `text` (plain, as the page shows it) in the elements of those lines, or the
    /// elements themselves when it is not found; `window.__nookHighlight()` clears it.
    /// Checked against the book theme of mystmd 1.11: 96 of 96 blocks matched on a 500-line page.
    public static let scrollSync = """
    (function () {
      if (window.top !== window) return;
      var headingSelector = 'article h1[id], article h2[id], article h3[id], article h4[id], article h5[id], article h6[id]';
      var blockSelector = 'article.article h1, article.article h2, article.article h3, article.article h4, ' +
        'article.article h5, article.article h6, article.article p, article.article pre, article.article .katex-display, article.article table';
      // Just below the theme's sticky top bar (its scroll-padding is 60 px).
      var LINE = 90;
      var headings = [], anchors = [], lastLine = 1;
      var current = -2, currentLine = null, currentEnd = 0, suppressUntil = 0, timer = null, ticking = false, started = false;
      var sentHeadings = null, signature = null, loadedPath = null, fetching = false;
      function post(message) {
        try { window.webkit.messageHandlers.\(syncHandlerName).postMessage(message); } catch (e) {}
      }
      function norm(text) { return (text || '').toLowerCase().replace(/[^\\p{L}\\p{N}]+/gu, ''); }

      // MARK: Headings (fallback and section reports)
      function collectHeadings(initial) {
        headings = Array.prototype.slice.call(document.querySelectorAll(headingSelector));
        var items = headings.map(function (h) {
          return { id: h.id, text: h.textContent.replace(/\\u00b6\\s*$/, '').trim(), level: Number(h.tagName.charAt(1)) };
        });
        // The theme changes the page while scrolling (e.g. the highlighted section in its
        // table of contents); send the list only when the headings themselves changed.
        var key = JSON.stringify(items);
        if (initial || key !== sentHeadings) {
          sentHeadings = key;
          post({ type: 'headings', initial: initial, items: items });
        }
      }
      function topIndex() {
        var index = -1;
        for (var i = 0; i < headings.length; i++) {
          if (headings[i].getBoundingClientRect().top <= LINE) index = i; else break;
        }
        return index;
      }

      // MARK: Source lines
      function blocksOf(mdast) {
        var kinds = { heading: 1, paragraph: 1, code: 1, math: 1, table: 1 }, blocks = [];
        function textOf(node, parts) {
          if (!node) return;
          if (node.type === 'text' || node.type === 'inlineCode') parts.push(node.value || '');
          if (node.type === 'inlineMath' || node.type === 'footnoteReference') return;
          (node.children || []).forEach(function (child) { textOf(child, parts); });
        }
        function walk(node) {
          if (!node) return;
          if (kinds[node.type] && node.position) {
            var parts = [];
            if (node.type === 'code' || node.type === 'math') parts.push(node.value || ''); else textOf(node, parts);
            // The longest piece of plain text identifies the block; roles, references and math
            // render differently from their source.
            var key = parts.map(norm).sort(function (a, b) { return b.length - a.length; })[0] || '';
            blocks.push({ start: node.position.start.line, end: node.position.end.line, key: key.slice(0, 40) });
            return;
          }
          (node.children || []).forEach(walk);
        }
        walk(mdast);
        return blocks;
      }
      function match(blocks) {
        var elements = Array.prototype.slice.call(document.querySelectorAll(blockSelector))
          .filter(function (e) { return !e.closest('.myst-fm-block, .myst-footer-links, .myst-footnotes, pre p, table p'); });
        var texts = elements.map(function (e) { return norm(e.textContent); });
        var result = [], next = 0;
        blocks.forEach(function (block) {
          if (block.key.length < 4) return;
          for (var k = next; k < Math.min(elements.length, next + 25); k++) {
            if (texts[k].indexOf(block.key) >= 0) {
              result.push({ start: block.start, end: block.end, el: elements[k] });
              next = k + 1;
              return;
            }
          }
        });
        return result;
      }
      function jsonPath() {
        return (location.pathname.replace(/\\/+$/, '') || '/index') + '.json';
      }
      function loadLines() {
        if (fetching) return;
        fetching = true;
        var path = jsonPath();
        fetch(path, { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).then(function (data) {
          fetching = false;
          if (!data || !data.mdast) { anchors = []; post({ type: 'anchors', count: 0, lines: 0 }); return; }
          loadedPath = path;
          var blocks = blocksOf(data.mdast);
          anchors = match(blocks);
          lastLine = Math.max(1, (data.mdast.position && data.mdast.position.end.line) ||
            (blocks.length ? blocks[blocks.length - 1].end + 1 : 1));
          post({ type: 'anchors', count: anchors.length, blocks: blocks.length, lines: lastLine });
          currentLine = null;
          update();
        }).catch(function () { fetching = false; anchors = []; });
      }
      /// (source line, page y) pairs, both increasing: each element's top and bottom.
      function points() {
        var list = [{ line: 1, y: 0 }], scroll = window.scrollY;
        for (var i = 0; i < anchors.length; i++) {
          var a = anchors[i];
          if (!a.el.isConnected) return null;
          var rect = a.el.getBoundingClientRect();
          var top = rect.top + scroll, bottom = rect.bottom + scroll, last = list[list.length - 1];
          if (a.start > last.line && top >= last.y) list.push({ line: a.start, y: top });
          last = list[list.length - 1];
          if (a.end + 1 > last.line && bottom >= last.y) list.push({ line: a.end + 1, y: bottom });
        }
        var end = list[list.length - 1], height = document.documentElement.scrollHeight;
        if (lastLine > end.line && height > end.y) list.push({ line: lastLine, y: height });
        return list;
      }
      function interpolate(list, from, to, value) {
        if (value <= list[0][from]) return list[0][to];
        for (var i = 1; i < list.length; i++) {
          var a = list[i - 1], b = list[i];
          if (value <= b[from]) {
            var span = b[from] - a[from];
            return span > 0 ? a[to] + (b[to] - a[to]) * (value - a[from]) / span : a[to];
          }
        }
        return list[list.length - 1][to];
      }
      /// 0 until the last screenful, then rising to 1 at the bottom.
      function endWeight() {
        var max = document.documentElement.scrollHeight - window.innerHeight;
        var zone = Math.min(window.innerHeight, max);
        if (zone <= 0) return 0;
        return Math.max(0, Math.min(1, 1 - (max - window.scrollY) / zone));
      }
      function topLine() {
        if (anchors.length < 2) return null;
        var list = points();
        if (!list) { loadLines(); return null; }
        return interpolate(list, 'y', 'line', window.scrollY + LINE);
      }

      // MARK: Reporting and scrolling
      function update() {
        var index = topIndex(), line = topLine(), end = Math.round(endWeight() * 100) / 100;
        var rounded = line === null ? null : Math.round(line * 10) / 10;
        if (index === current && rounded === currentLine && end === currentEnd) return;
        current = index;
        currentLine = rounded;
        currentEnd = end;
        if (Date.now() < suppressUntil) return;
        post({ type: 'scroll', index: index, line: rounded, end: end });
      }
      window.addEventListener('scroll', function () {
        if (ticking) return;
        ticking = true;
        requestAnimationFrame(function () { ticking = false; update(); });
      }, { passive: true });
      window.__nookScrollToLine = function (line, heading, animated, end) {
        // Our own scrolling must not be reported back as the reader's.
        suppressUntil = Date.now() + (animated ? 900 : 250);
        var behavior = animated ? 'smooth' : 'auto';
        var list = line !== null && anchors.length >= 2 ? points() : null;
        if (list) {
          var y = interpolate(list, 'line', 'y', line) - LINE;
          // Near the other side's end, move towards this page's end, so both arrive together.
          var max = document.documentElement.scrollHeight - window.innerHeight;
          if (end > 0 && max > y) y += end * (max - y);
          window.scrollTo({ top: Math.max(0, Math.min(max, y)), behavior: behavior });
        } else if (heading < 0 || !headings[heading]) {
          window.scrollTo({ top: 0, behavior: behavior });
        } else {
          headings[heading].scrollIntoView({ block: 'start', behavior: behavior });
        }
        current = topIndex();
        currentLine = null;
      };
      // MARK: Selection highlighting
      var style = document.createElement('style');
      style.textContent = '::highlight(nook-sync) { background-color: rgba(255, 214, 0, 0.55); color: inherit; }' +
        '.nook-sync-block { background-color: rgba(255, 214, 0, 0.28); border-radius: 3px; box-shadow: 0 0 0 3px rgba(255, 214, 0, 0.28); }';
      (document.head || document.documentElement).appendChild(style);
      var marked = [];
      function clearHighlight() {
        if (window.CSS && CSS.highlights) CSS.highlights.delete('nook-sync');
        marked.forEach(function (e) { e.classList.remove('nook-sync-block'); });
        marked = [];
      }
      /// A Range over the first occurrence of `needle` (normalized) in `elements`' text, or null.
      function findText(elements, needle) {
        for (var n = 0; n < elements.length; n++) {
          var walker = document.createTreeWalker(elements[n], NodeFilter.SHOW_TEXT, {
            acceptNode: function (node) { return node.parentElement && node.parentElement.closest('.katex, .sr-only') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; }
          });
          // Normalized text of the element with, for each of its characters, the text node and offset.
          var text = '', map = [], node, lastSpace = true;
          while ((node = walker.nextNode())) {
            var value = node.nodeValue;
            for (var i = 0; i < value.length; i++) {
              var c = value[i];
              if (/\\s/.test(c)) { if (lastSpace) continue; c = ' '; lastSpace = true; } else { lastSpace = false; }
              text += c.toLowerCase();
              map.push([node, i]);
            }
          }
          var at = text.indexOf(needle);
          if (at >= 0) {
            var range = document.createRange();
            range.setStart(map[at][0], map[at][1]);
            var last = map[at + needle.length - 1];
            range.setEnd(last[0], last[1] + 1);
            return range;
          }
        }
        return null;
      }
      window.__nookHighlight = function (start, end, text) {
        clearHighlight();
        if (start === undefined || start === null) return;
        var elements = anchors.filter(function (a) { return a.start <= end && a.end >= start && a.el.isConnected; })
          .map(function (a) { return a.el; });
        if (!elements.length) return;
        var needle = (text || '').toLowerCase().replace(/\\s+/g, ' ').trim();
        var range = needle.length >= 2 && window.CSS && CSS.highlights && window.Highlight ? findText(elements, needle) : null;
        if (range) {
          CSS.highlights.set('nook-sync', new Highlight(range));
        } else {
          elements.forEach(function (e) { e.classList.add('nook-sync-block'); });
          marked = elements;
        }
      };
      var selectionTimer = null, hadSelection = false;
      document.addEventListener('selectionchange', function () {
        clearTimeout(selectionTimer);
        selectionTimer = setTimeout(function () {
          var selection = document.getSelection();
          var text = selection && !selection.isCollapsed ? selection.toString().trim() : '';
          if (!text) {
            if (hadSelection) post({ type: 'selection', text: '' });
            hadSelection = false;
            return;
          }
          var list = anchors.length >= 2 ? points() : null;
          if (!list) return;
          var rect = selection.getRangeAt(0).getBoundingClientRect();
          var top = rect.top + window.scrollY, bottom = rect.bottom + window.scrollY;
          hadSelection = true;
          // Our own highlight is not shown while the reader selects here.
          clearHighlight();
          post({ type: 'selection', text: text.slice(0, 2000),
                 start: Math.floor(interpolate(list, 'y', 'line', top + 1)), end: Math.ceil(interpolate(list, 'y', 'line', bottom - 1)) });
        }, 150);
      });

      // Kept for older callers: scrolls to a heading.
      window.__nookScrollToHeading = function (index, animated) { window.__nookScrollToLine(null, index, animated); };
      function pageSignature() {
        var article = document.querySelector('article.article');
        return location.pathname + ':' + (article ? article.textContent.length : 0);
      }
      function refresh(initial) {
        collectHeadings(initial);
        var now = pageSignature();
        // A new page, or its text changed (an in-place refresh after a save): match again.
        if (initial || now !== signature || jsonPath() !== loadedPath) {
          signature = now;
          loadLines();
        }
        current = topIndex();
      }
      function start() {
        if (started) return;
        started = true;
        refresh(true);
        new MutationObserver(function () {
          clearTimeout(timer);
          timer = setTimeout(function () { refresh(false); }, 200);
        }).observe(document.body, { childList: true, subtree: true, characterData: true });
      }
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
    })();
    """
}

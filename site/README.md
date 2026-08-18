# EZLibrary website

The public site at **https://tawaunl.github.io/EZLibrary/**.

Plain static HTML and CSS with a little vanilla JavaScript. No build step, no
framework, no dependencies — the whole directory is what gets served.

## Layout

```
site/
  index.html            landing page
  features/index.html   feature overview
  features/*.html       one page per feature   ← generated, see below
  support/index.html    install help, how-to guides, FAQ, contact
  roadmap/index.html    live 3-column board
  404.html
  assets/css/site.css   every style on the site
  assets/js/site.js     nav, screenshot tabs, latest-release lookup
  assets/js/roadmap.js  the roadmap board
  assets/img/           icon and app screenshots
```

## Editing

Everything except `features/` is edited directly.

`site/features/` is **generated** by `Scripts/build-site-pages.py`, because ten
pages sharing one layout drift apart the moment they're maintained by hand. Edit
the `FEATURES` table in that script and re-run it:

```bash
./Scripts/build-site-pages.py
```

Commit the regenerated HTML — the deploy publishes the directory as-is and never
runs the script.

## Preview locally

```bash
python3 -m http.server 8000 --directory site
```

Then open <http://localhost:8000>. Links are relative, so this behaves the same
as the deployed site.

## Deploying

`.github/workflows/pages.yml` publishes `site/` to GitHub Pages on every push to
`main` that touches it, and can be run by hand from the Actions tab.

## Two things that pull live data

Both are progressive enhancement — the pages are complete and correct without
JavaScript, and both fall back silently if GitHub is unreachable or rate-limits
the request.

**Download buttons** ship with an href pointing at the releases page, and are
upgraded to a direct `.pkg` link once `releases/latest` answers. The version and
size shown on the page come from the same response; the hardcoded values in the
HTML are the fallback, so bump them when they get stale.

## Analytics

`assets/js/site.js` loads [GoatCounter](https://www.goatcounter.com) (cookieless,
no consent banner) for every page, so no per-page markup is needed. Page views go
to `https://ezlibrary.goatcounter.com`, and each Download button click is also
recorded as a `download-<version>` event. Create the `ezlibrary` site in
GoatCounter for the data to land; if it is unreachable, nothing else breaks.

**The roadmap board** is a view over GitHub Issues labelled `roadmap`:

| Column | Comes from |
|---|---|
| Requested & Planned | open, sorted by 👍 reactions |
| In Progress | open, plus the `in progress` label |
| Recently Completed | closed, newest first, capped at nine |

A 👍 reaction on the issue is the vote. The `roadmap` label is applied
automatically by the feature-request issue template, so a new request appears on
the board straight away; remove the label to take something off it.

Issue titles and bodies are other people's text and are inserted with
`textContent`, never `innerHTML`.

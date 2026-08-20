# Roadmap voting backend

These Netlify Functions let visitors upvote and post roadmap ideas from the
website itself, while GitHub Issues stays the single source of truth. The static
site (GitHub Pages) does the reading; these functions do the writing.

- `login` — exchanges the GitHub OAuth `code` for a token and returns an
  encrypted session blob. The token and OAuth secret never reach the browser.
- `vote` — adds/removes the signed-in user's 👍 reaction on an issue.
- `submit` — opens a new issue as the user and labels it `roadmap`.

The site keeps working without any of this — if the functions or config are
missing, the vote buttons fall back to linking to GitHub, exactly as before.

## One-time setup

### 1. Register a GitHub OAuth App

<https://github.com/settings/developers> → **New OAuth App**

- **Homepage URL:** `https://tawaunl.github.io/EZLibrary/`
- **Authorization callback URL:** `https://tawaunl.github.io/EZLibrary/roadmap/`

Copy the **Client ID** and generate a **Client secret**.

### 2. (Optional but recommended) Create a bot token for labelling

GitHub drops the `roadmap` label when a non-collaborator opens an issue, so new
requests wouldn't appear on the board. To auto-label them, create a
[fine-grained personal access token](https://github.com/settings/tokens?type=beta)
scoped to the `EZLibrary` repo with **Issues: Read and write**, and set it as
`ROADMAP_BOT_TOKEN`. Without it, issues are still created — a maintainer just
adds the `roadmap` label manually.

### 3. Deploy to Netlify

Create a Netlify site from this repo (it picks up `netlify.toml`). Set these
environment variables under **Site settings → Environment variables**:

| Variable               | Value                                             |
| ---------------------- | ------------------------------------------------- |
| `GITHUB_CLIENT_ID`     | OAuth App client ID                               |
| `GITHUB_CLIENT_SECRET` | OAuth App client secret                           |
| `SESSION_SECRET`       | A long random string (e.g. `openssl rand -hex 32`)|
| `ALLOWED_ORIGIN`       | `https://tawaunl.github.io`                       |
| `ROADMAP_BOT_TOKEN`    | Fine-grained token from step 2 (optional)         |
| `ROADMAP_REPO`         | `tawaunl/EZLibrary` (optional, this is default)   |

Note the deployed functions base, e.g.
`https://YOUR-SITE.netlify.app/.netlify/functions`.

### 4. Point the site at the backend

In `site/roadmap/index.html`, fill in the two `data-` attributes on the board:

```html
<div id="board" class="board"
     data-oauth-client-id="YOUR_OAUTH_CLIENT_ID"
     data-functions-base="https://YOUR-SITE.netlify.app/.netlify/functions">
```

Commit and push. That's it — the board now votes and posts in place.

## Local testing

```bash
npm install -g netlify-cli
netlify dev
```

`netlify dev` serves `site/` and the functions together on one origin, so set
`data-functions-base="/.netlify/functions"` (and add `http://localhost:8888` to
`ALLOWED_ORIGIN`) while testing locally.

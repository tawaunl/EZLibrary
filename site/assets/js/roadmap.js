/* EZLibrary — public roadmap board.

   The board is a view over GitHub Issues labelled `roadmap`, read through the
   public REST API (no token, no build step). A card's position comes from its
   labels and state; its rank comes from 👍 reactions, so the column order is
   whatever the community has voted up.

   Writing back — voting and posting ideas — happens in place when the board is
   configured with an OAuth client id and a functions base (the two data-
   attributes on #board; see netlify/README.md). Visitors sign in with GitHub
   once; the encrypted session lives in the browser while the real GitHub token
   stays on the server. When that config is absent the board degrades to exactly
   what it was before: the vote button just links out to GitHub.

   Labels that drive the board:
     roadmap          every card, in any column
     in progress      moves a card to the middle column
     (closed issue)   moves a card to Recently Completed

   Issue titles and bodies are other people's text: everything is inserted with
   textContent, never innerHTML. The only innerHTML used is a constant SVG. */

(function () {
  "use strict";

  var REPO = "tawaunl/EZLibrary";
  var CACHE_KEY = "ezlibrary-roadmap-v1";
  var CACHE_MS = 10 * 60 * 1000;
  var COMPLETED_LIMIT = 9;
  var BODY_CHARS = 165;

  var SESSION_KEY = "ezlibrary-roadmap-session-v1";
  var STATE_KEY = "ezlibrary-roadmap-oauth-state";
  var INTENT_KEY = "ezlibrary-roadmap-intent";

  var ARROW_SVG =
    '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="2.4" stroke-linecap="round" ' +
    'stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5M5 12l7-7 7 7"/></svg>';

  var board = document.getElementById("board");
  if (!board) return;

  var CLIENT_ID = (board.dataset.oauthClientId || "").trim();
  var FUNCTIONS = (board.dataset.functionsBase || "").trim().replace(/\/+$/, "");
  var AUTH_ENABLED = !!(CLIENT_ID && FUNCTIONS);

  var session = readSession();

  var COLUMNS = [
    {
      id: "planned",
      match: function (issue) {
        return issue.state === "open" && !hasLabel(issue, "in progress");
      },
      sort: byVotes,
      empty:
        "Nothing queued up right now. Post an idea and it lands here once it's accepted."
    },
    {
      id: "progress",
      match: function (issue) {
        return issue.state === "open" && hasLabel(issue, "in progress");
      },
      sort: byVotes,
      empty: "Nothing actively being built at the moment."
    },
    {
      id: "done",
      match: function (issue) {
        return issue.state === "closed";
      },
      sort: function (a, b) {
        return Date.parse(b.closed_at || 0) - Date.parse(a.closed_at || 0);
      },
      limit: COMPLETED_LIMIT,
      empty: "Shipped work will show up here."
    }
  ];

  wireSuggestForm();
  boot();

  function boot() {
    handleCallback()
      .then(function () {
        renderAuthBar();
        wireSuggestButtons();
        resumeIntent();
        return load();
      })
      .then(render)
      .catch(function (error) {
        showStatus(
          "Couldn't load the live board (" +
            error.message +
            "). " +
            "You can always see the same list on GitHub.",
          true
        );
      });
  }

  /* ----------------------------------------------------------------- data */

  function load() {
    var cached = readCache();
    if (cached) return Promise.resolve(cached);

    return fetch(
      "https://api.github.com/repos/" +
        REPO +
        "/issues?state=all&labels=roadmap&per_page=100&sort=updated&direction=desc",
      { headers: { Accept: "application/vnd.github+json" } }
    )
      .then(function (response) {
        if (response.status === 403) throw new Error("GitHub rate limit reached");
        if (!response.ok) throw new Error("HTTP " + response.status);
        return response.json();
      })
      .then(function (issues) {
        var list = (issues || []).filter(function (issue) {
          return !issue.pull_request;
        });
        writeCache(list);
        return list;
      });
  }

  function readCache() {
    try {
      var raw = window.localStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      var entry = JSON.parse(raw);
      if (!entry || Date.now() - entry.at > CACHE_MS) return null;
      return entry.issues;
    } catch (error) {
      return null;
    }
  }

  function writeCache(issues) {
    try {
      window.localStorage.setItem(
        CACHE_KEY,
        JSON.stringify({ at: Date.now(), issues: issues })
      );
    } catch (error) {
      /* Private browsing or a full quota: the board just refetches next time. */
    }
  }

  function clearCache() {
    try {
      window.localStorage.removeItem(CACHE_KEY);
    } catch (error) {
      /* nothing to do */
    }
  }

  /* Force a fresh pull (after posting a new idea) and re-render. */
  function reload() {
    clearCache();
    load().then(render).catch(function () {});
  }

  /* ---------------------------------------------------------------- render */

  function render(issues) {
    if (!issues.length) {
      showStatus("No roadmap items yet — be the first to suggest one.", false);
      return;
    }

    COLUMNS.forEach(function (column) {
      var body = document.getElementById("col-" + column.id);
      var count = document.getElementById("count-" + column.id);
      if (!body) return;

      var items = issues.filter(column.match).sort(column.sort);
      var shown = column.limit ? items.slice(0, column.limit) : items;

      body.textContent = "";
      if (count) count.textContent = String(items.length);

      if (!shown.length) {
        body.appendChild(el("p", "column-empty", column.empty));
        return;
      }
      shown.forEach(function (issue) {
        body.appendChild(card(issue));
      });
    });
  }

  function card(issue) {
    var item = el("div", "item");
    item.appendChild(voteControl(issue));

    var main = el("div", "item-main");

    var heading = el("h4");
    var link = el("a", null, issue.title);
    link.href = issue.html_url;
    link.target = "_blank";
    link.rel = "noopener";
    heading.appendChild(link);
    main.appendChild(heading);

    var summary = excerpt(issue.body);
    if (summary) main.appendChild(el("p", null, summary));

    var meta = el("div", "item-meta");
    meta.appendChild(el("span", "tag", "#" + issue.number));

    topicLabels(issue).forEach(function (label) {
      meta.appendChild(el("span", "tag", label));
    });

    if (issue.state === "closed" && issue.closed_at) {
      meta.appendChild(el("span", "tag", "Shipped " + monthYear(issue.closed_at)));
    }
    if (issue.comments) {
      meta.appendChild(
        el(
          "span",
          "tag tag-comments",
          issue.comments + (issue.comments === 1 ? " comment" : " comments")
        )
      );
    }
    main.appendChild(meta);

    item.appendChild(main);
    return item;
  }

  /* ------------------------------------------------------------------ vote */

  function voteControl(issue) {
    var votes = votesFor(issue);

    /* No backend configured: keep the original link-to-GitHub behaviour. */
    if (!AUTH_ENABLED) {
      var link = el("a", "vote");
      link.href = issue.html_url;
      link.target = "_blank";
      link.rel = "noopener";
      link.title = "Open on GitHub and react with 👍 to vote";
      link.setAttribute(
        "aria-label",
        "Vote for “" + issue.title + "” on GitHub. " + votes + " votes so far."
      );
      link.innerHTML = ARROW_SVG;
      link.appendChild(el("b", null, String(votes)));
      link.appendChild(el("small", null, "vote"));
      return link;
    }

    var button = document.createElement("button");
    button.type = "button";
    button.className = "vote";
    paintVote(button, issue, hasVoted(issue.number), votes);
    button.addEventListener("click", function () {
      toggleVote(issue, button);
    });
    return button;
  }

  function paintVote(button, issue, voted, count) {
    button.classList.toggle("is-voted", voted);
    button.setAttribute("aria-pressed", voted ? "true" : "false");
    button.setAttribute(
      "aria-label",
      (voted ? "Remove your vote for “" : "Vote for “") +
        issue.title +
        "”. " +
        count +
        " votes so far."
    );
    button.title = voted ? "Remove your vote" : "Vote for this";
    button.innerHTML = ARROW_SVG;
    button.appendChild(el("b", null, String(count)));
    button.appendChild(el("small", null, voted ? "voted" : "vote"));
  }

  function toggleVote(issue, button) {
    if (!session) {
      startLogin();
      return;
    }

    var votes = votedMap();
    var wasVoted = Object.prototype.hasOwnProperty.call(votes, issue.number);
    var reactionId = votes[issue.number];
    var countNode = button.querySelector("b");
    var count = parseInt(countNode.textContent, 10) || 0;
    var optimistic = Math.max(0, wasVoted ? count - 1 : count + 1);

    paintVote(button, issue, !wasVoted, optimistic);
    button.disabled = true;

    apiFetch("/vote", {
      issue: issue.number,
      action: wasVoted ? "remove" : "add",
      reactionId: wasVoted ? reactionId : undefined
    })
      .then(function (data) {
        if (wasVoted) clearVote(issue.number);
        else setVote(issue.number, data.reactionId);
        button.disabled = false;
      })
      .catch(function (error) {
        paintVote(button, issue, wasVoted, count);
        button.disabled = false;
        if (!session) renderAuthBar();
        toast(error.message || "Couldn't record your vote.");
      });
  }

  /* ------------------------------------------------------------------ auth */

  /* Unauthenticated POST — used only for the code exchange. */
  function authFetch(path, body) {
    return fetch(FUNCTIONS + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body || {})
    });
  }

  /* Authenticated POST carrying the session; normalises errors and expiry. */
  function apiFetch(path, body) {
    return fetch(FUNCTIONS + path, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + session.session
      },
      body: JSON.stringify(body || {})
    }).then(function (response) {
      if (response.status === 401) {
        clearSession();
        renderAuthBar();
        throw new Error("Your session expired — please sign in again.");
      }
      return response.json().then(function (data) {
        if (!response.ok)
          throw new Error((data && data.error) || "Something went wrong.");
        return data;
      });
    });
  }

  function startLogin(intent) {
    var state = randomState();
    try {
      window.sessionStorage.setItem(STATE_KEY, state);
      if (intent) window.sessionStorage.setItem(INTENT_KEY, intent);
    } catch (error) {
      /* sessionStorage unavailable — the state check below is skipped */
    }
    var redirect = location.origin + location.pathname;
    location.assign(
      "https://github.com/login/oauth/authorize" +
        "?client_id=" +
        encodeURIComponent(CLIENT_ID) +
        "&scope=public_repo" +
        "&state=" +
        encodeURIComponent(state) +
        "&redirect_uri=" +
        encodeURIComponent(redirect)
    );
  }

  /* Back from GitHub with a ?code=? Trade it for a session, then clean the URL. */
  function handleCallback() {
    if (!AUTH_ENABLED) return Promise.resolve(false);

    var params = new URLSearchParams(location.search);
    var code = params.get("code");
    if (!code) return Promise.resolve(false);

    var returned = params.get("state");
    var expected = null;
    try {
      expected = window.sessionStorage.getItem(STATE_KEY);
      window.sessionStorage.removeItem(STATE_KEY);
    } catch (error) {
      /* ignore */
    }

    history.replaceState({}, "", location.pathname);
    if (!returned || returned !== expected) return Promise.resolve(false);

    return authFetch("/login", { code: code })
      .then(function (response) {
        return response.json();
      })
      .then(function (data) {
        if (data && data.session) {
          saveSession(data);
          return true;
        }
        toast((data && data.error) || "Sign-in failed.");
        return false;
      })
      .catch(function () {
        toast("Sign-in failed. Please try again.");
        return false;
      });
  }

  /* If the visitor clicked "Suggest an idea" before signing in, reopen the
     form once they land back here signed in. */
  function resumeIntent() {
    var intent = null;
    try {
      intent = window.sessionStorage.getItem(INTENT_KEY);
      window.sessionStorage.removeItem(INTENT_KEY);
    } catch (error) {
      /* ignore */
    }
    if (intent === "suggest" && session) openSuggest();
  }

  function renderAuthBar() {
    var bar = document.getElementById("board-auth");
    if (!bar) return;
    bar.textContent = "";

    if (!AUTH_ENABLED) {
      bar.hidden = true;
      return;
    }
    bar.hidden = false;

    if (session) {
      var who = el("span", "auth-who");
      if (session.user && session.user.avatar_url) {
        var avatar = document.createElement("img");
        avatar.src = session.user.avatar_url;
        avatar.alt = "";
        avatar.width = 22;
        avatar.height = 22;
        who.appendChild(avatar);
      }
      who.appendChild(
        el(
          "span",
          null,
          "Signed in as " + (session.user ? session.user.login : "you")
        )
      );
      bar.appendChild(who);

      var actions = el("span", "auth-actions");
      var suggest = el("button", "btn btn-sm btn-primary", "Suggest an idea");
      suggest.type = "button";
      suggest.addEventListener("click", function () {
        openSuggest();
      });
      actions.appendChild(suggest);

      var signOut = el("button", "btn btn-sm", "Sign out");
      signOut.type = "button";
      signOut.addEventListener("click", function () {
        clearSession();
        renderAuthBar();
        render(readCache() || []);
      });
      actions.appendChild(signOut);
      bar.appendChild(actions);
    } else {
      bar.appendChild(
        el(
          "span",
          "auth-who",
          "Sign in with GitHub to vote and post ideas right here."
        )
      );
      var signIn = el("button", "btn btn-sm btn-primary", "Sign in with GitHub");
      signIn.type = "button";
      signIn.addEventListener("click", function () {
        startLogin();
      });
      var actionsOut = el("span", "auth-actions");
      actionsOut.appendChild(signIn);
      bar.appendChild(actionsOut);
    }
  }

  function readSession() {
    try {
      return JSON.parse(window.localStorage.getItem(SESSION_KEY)) || null;
    } catch (error) {
      return null;
    }
  }

  function saveSession(data) {
    session = { session: data.session, user: data.user };
    try {
      window.localStorage.setItem(SESSION_KEY, JSON.stringify(session));
    } catch (error) {
      /* ignore */
    }
  }

  function clearSession() {
    session = null;
    try {
      window.localStorage.removeItem(SESSION_KEY);
    } catch (error) {
      /* ignore */
    }
  }

  /* Which issues this account has voted for, kept per-login so switching
     accounts doesn't inherit someone else's votes. Maps issue -> reaction id. */
  function votesKey() {
    return (
      "ezlibrary-roadmap-votes-" +
      (session && session.user ? session.user.login : "anon")
    );
  }

  function votedMap() {
    try {
      return JSON.parse(window.localStorage.getItem(votesKey())) || {};
    } catch (error) {
      return {};
    }
  }

  function hasVoted(number) {
    return Object.prototype.hasOwnProperty.call(votedMap(), number);
  }

  function setVote(number, reactionId) {
    var map = votedMap();
    map[number] = reactionId || true;
    persistVotes(map);
  }

  function clearVote(number) {
    var map = votedMap();
    delete map[number];
    persistVotes(map);
  }

  function persistVotes(map) {
    try {
      window.localStorage.setItem(votesKey(), JSON.stringify(map));
    } catch (error) {
      /* ignore */
    }
  }

  /* --------------------------------------------------------------- suggest */

  function wireSuggestButtons() {
    if (!AUTH_ENABLED) return; // leave the GitHub links as-is
    var triggers = document.querySelectorAll("[data-suggest]");
    Array.prototype.forEach.call(triggers, function (trigger) {
      trigger.addEventListener("click", function (event) {
        event.preventDefault();
        if (!session) startLogin("suggest");
        else openSuggest();
      });
    });
  }

  function openSuggest() {
    var dialog = document.getElementById("suggest-dialog");
    if (!dialog) return;
    resetSuggest();
    if (typeof dialog.showModal === "function") dialog.showModal();
    else dialog.setAttribute("open", "");
    var title = document.getElementById("suggest-title");
    if (title) title.focus();
  }

  function closeSuggest() {
    var dialog = document.getElementById("suggest-dialog");
    if (!dialog) return;
    if (typeof dialog.close === "function") dialog.close();
    else dialog.removeAttribute("open");
  }

  function resetSuggest() {
    var form = document.getElementById("suggest-form");
    var status = document.getElementById("suggest-status");
    var submit = document.getElementById("suggest-submit");
    if (form) {
      form.hidden = false;
      form.reset();
    }
    if (status) {
      status.textContent = "";
      status.className = "suggest-status";
    }
    if (submit) submit.disabled = false;
  }

  function wireSuggestForm() {
    var dialog = document.getElementById("suggest-dialog");
    var form = document.getElementById("suggest-form");
    if (!dialog || !form) return;

    Array.prototype.forEach.call(
      dialog.querySelectorAll("[data-close]"),
      function (node) {
        node.addEventListener("click", function () {
          closeSuggest();
        });
      }
    );

    form.addEventListener("submit", function (event) {
      event.preventDefault();
      if (!session) {
        startLogin("suggest");
        return;
      }
      var titleInput = document.getElementById("suggest-title");
      var bodyInput = document.getElementById("suggest-body");
      var submit = document.getElementById("suggest-submit");

      var title = (titleInput.value || "").trim();
      if (title.length < 6) {
        setSuggestStatus("Give your idea a clearer title first.", true);
        titleInput.focus();
        return;
      }

      submit.disabled = true;
      setSuggestStatus("Posting your idea…", false);

      apiFetch("/submit", { title: title, body: bodyInput.value || "" })
        .then(function (data) {
          form.hidden = true;
          var status = document.getElementById("suggest-status");
          status.className = "suggest-status is-ok";
          status.textContent = "Posted as #" + data.number + " — ";
          var link = el("a", null, "view it on GitHub");
          link.href = data.url;
          link.target = "_blank";
          link.rel = "noopener";
          status.appendChild(link);
          status.appendChild(
            document.createTextNode(". It's on the board now.")
          );
          reload();
        })
        .catch(function (error) {
          submit.disabled = false;
          setSuggestStatus(error.message || "Couldn't post your idea.", true);
        });
    });
  }

  function setSuggestStatus(message, isError) {
    var status = document.getElementById("suggest-status");
    if (!status) return;
    status.className = "suggest-status" + (isError ? " is-error" : "");
    status.textContent = message;
  }

  /* --------------------------------------------------------------- status */

  function showStatus(message, isError) {
    board.textContent = "";
    var status = el("p", "board-status", message);
    if (isError) {
      status.appendChild(document.createElement("br"));
      var link = el("a", null, "Open the roadmap on GitHub →");
      link.href = "https://github.com/" + REPO + "/issues?q=label%3Aroadmap";
      status.appendChild(link);
    }
    board.appendChild(status);
  }

  var toastTimer = null;
  function toast(message) {
    var node = document.getElementById("board-toast");
    if (!node) return;
    node.textContent = message;
    node.classList.add("show");
    if (toastTimer) window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      node.classList.remove("show");
    }, 4200);
  }

  /* ----------------------------------------------------------------- utils */

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function randomState() {
    if (window.crypto && window.crypto.getRandomValues) {
      var bytes = new Uint8Array(16);
      window.crypto.getRandomValues(bytes);
      return Array.prototype.map
        .call(bytes, function (b) {
          return ("0" + b.toString(16)).slice(-2);
        })
        .join("");
    }
    return String(Date.now()) + Math.random().toString(16).slice(2);
  }

  function hasLabel(issue, name) {
    return (issue.labels || []).some(function (label) {
      return (label.name || label).toLowerCase() === name;
    });
  }

  /* Labels worth showing on a card: not the plumbing ones the board uses. */
  function topicLabels(issue) {
    var hidden = ["roadmap", "in progress", "enhancement", "good first issue"];
    return (issue.labels || [])
      .map(function (label) {
        return label.name || label;
      })
      .filter(function (name) {
        return hidden.indexOf(name.toLowerCase()) === -1;
      })
      .slice(0, 2);
  }

  function votesFor(issue) {
    return (issue.reactions && issue.reactions["+1"]) || 0;
  }

  function byVotes(a, b) {
    var diff = votesFor(b) - votesFor(a);
    if (diff) return diff;
    return Date.parse(b.created_at || 0) - Date.parse(a.created_at || 0);
  }

  /* First real paragraph of the issue body, with the template's headings,
     comments and checkboxes stripped out. */
  function excerpt(body) {
    if (!body) return "";
    var text = body
      .replace(/<!--[\s\S]*?-->/g, "")
      .replace(/^#{1,6} .*$/gm, "")
      .replace(/^\s*[-*]\s+\[[ xX]\]\s*/gm, "")
      .replace(/```[\s\S]*?```/g, "")
      .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/[*_`>#]/g, "")
      .replace(/\r/g, "")
      .split("\n")
      .map(function (line) {
        return line.trim();
      })
      .filter(Boolean)
      .join(" ")
      .trim();

    if (text.length <= BODY_CHARS) return text;
    var cut = text.slice(0, BODY_CHARS);
    var space = cut.lastIndexOf(" ");
    return (space > 80 ? cut.slice(0, space) : cut) + "…";
  }

  function monthYear(iso) {
    var date = new Date(iso);
    if (isNaN(date)) return "";
    return date.toLocaleDateString(undefined, { month: "short", year: "numeric" });
  }
})();

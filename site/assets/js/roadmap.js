/* EZLibrary — public roadmap board.

   The board is a view over GitHub Issues labelled `roadmap`, read through the
   public REST API (no token, no build step). A card's position comes from its
   labels and state; its rank comes from 👍 reactions, so the column order is
   whatever the community has voted up.

   Labels that drive the board:
     roadmap          every card, in any column
     in progress      moves a card to the middle column
     (closed issue)   moves a card to Recently Completed

   Issue titles and bodies are other people's text: everything is inserted with
   textContent, never innerHTML. */

(function () {
  "use strict";

  var REPO = "tawaunl/EZLibrary";
  var CACHE_KEY = "ezlibrary-roadmap-v1";
  var CACHE_MS = 10 * 60 * 1000;
  var COMPLETED_LIMIT = 9;
  var BODY_CHARS = 165;

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

  var board = document.getElementById("board");
  if (!board) return;

  load()
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

  /* ---------------------------------------------------------------- render */

  function render(issues) {
    if (!issues.length) {
      showStatus(
        "No roadmap items yet — be the first to suggest one.",
        false
      );
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

    var votes = votesFor(issue);
    var vote = el("a", "vote");
    vote.href = issue.html_url;
    vote.target = "_blank";
    vote.rel = "noopener";
    vote.title = "Open on GitHub and react with 👍 to vote";
    vote.setAttribute(
      "aria-label",
      "Vote for “" + issue.title + "” on GitHub. " + votes + " votes so far."
    );
    vote.innerHTML =
      '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" ' +
      'stroke="currentColor" stroke-width="2.4" stroke-linecap="round" ' +
      'stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5M5 12l7-7 7 7"/></svg>';
    vote.appendChild(el("b", null, String(votes)));
    vote.appendChild(el("small", null, "vote"));
    item.appendChild(vote);

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
      var comments = el(
        "span",
        "tag tag-comments",
        issue.comments + (issue.comments === 1 ? " comment" : " comments")
      );
      meta.appendChild(comments);
    }
    main.appendChild(meta);

    item.appendChild(main);
    return item;
  }

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

  /* ----------------------------------------------------------------- utils */

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
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

/* EZLibrary — shared site behaviour.
   Everything here is progressive enhancement: the pages work without it. */

(function () {
  "use strict";

  document.documentElement.classList.add("js");

  var REPO = "tawaunl/EZLibrary";

  /* ------------------------------------------------------------ mobile nav */

  var toggle = document.querySelector(".nav-toggle");
  var nav = document.getElementById("site-nav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  /* ---------------------------------------------------------- screenshot tabs */

  document.querySelectorAll("[data-tabs]").forEach(function (group) {
    var tabs = Array.prototype.slice.call(group.querySelectorAll(".tab"));
    var panels = Array.prototype.slice.call(
      document.querySelectorAll("#" + group.dataset.tabs + " .tab-panel")
    );
    if (!tabs.length || tabs.length !== panels.length) return;

    function select(index) {
      tabs.forEach(function (tab, i) {
        tab.setAttribute("aria-selected", i === index ? "true" : "false");
        tab.tabIndex = i === index ? 0 : -1;
        panels[i].hidden = i !== index;
      });
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () {
        select(i);
      });
      tab.addEventListener("keydown", function (event) {
        var next =
          event.key === "ArrowRight" ? i + 1 : event.key === "ArrowLeft" ? i - 1 : -1;
        if (next < 0 || next >= tabs.length) return;
        event.preventDefault();
        tabs[next].focus();
        select(next);
      });
    });

    select(0);
  });

  /* ------------------------------------------------------- latest release info

     Every download button ships with a working href pointing at the releases
     page. When the API answers we upgrade it to the direct .pkg link and fill
     in the version and size. If the request fails, nothing changes. */

  var versionSlots = document.querySelectorAll("[data-latest-version]");
  var sizeSlots = document.querySelectorAll("[data-latest-size]");
  var downloadLinks = document.querySelectorAll("[data-download]");
  if (!versionSlots.length && !downloadLinks.length) return;

  fetch("https://api.github.com/repos/" + REPO + "/releases/latest", {
    headers: { Accept: "application/vnd.github+json" }
  })
    .then(function (response) {
      if (!response.ok) throw new Error("HTTP " + response.status);
      return response.json();
    })
    .then(function (release) {
      var pkg = (release.assets || []).filter(function (asset) {
        return /\.pkg$/i.test(asset.name);
      })[0];

      var version = String(release.tag_name || "").replace(/^v/, "");
      if (version) {
        versionSlots.forEach(function (slot) {
          slot.textContent = version;
        });
      }

      if (pkg) {
        downloadLinks.forEach(function (link) {
          link.href = pkg.browser_download_url;
          if (version) link.setAttribute("data-version", version);
        });
        var mb = (pkg.size / 1048576).toFixed(1).replace(/\.0$/, "");
        sizeSlots.forEach(function (slot) {
          slot.textContent = mb + " MB";
        });
      }
    })
    .catch(function () {
      /* Offline, rate-limited, or blocked: the static hrefs already work. */
    });
})();

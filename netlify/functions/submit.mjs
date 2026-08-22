/* POST /submit  { title, body }  ->  { number, url, title }

   Opens a new GitHub issue as the signed-in user so the request keeps their
   authorship. GitHub silently drops labels supplied by non-collaborators, so
   the `roadmap` label (the thing that puts a card on the board) is applied in a
   second call using ROADMAP_BOT_TOKEN — a fine-grained token with Issues:write
   on the repo. Without that token the issue is still created; a maintainer just
   has to add the label before it shows on the board. */

import { json, preflight, sessionFrom, gh, env, REPO } from "./lib/shared.mjs";

const SIGNATURE =
  "\n\n---\n_Submitted from the [EZLibrary roadmap](https://tawaunl.github.io/EZLibrary/roadmap/)._";

export default async (request) => {
  const origin = request.headers.get("origin");
  if (request.method === "OPTIONS") return preflight(request);
  if (request.method !== "POST")
    return json({ error: "Method not allowed" }, 405, origin);

  const session = await sessionFrom(request);
  if (!session) return json({ error: "Please sign in again" }, 401, origin);

  let payload;
  try {
    payload = await request.json();
  } catch (error) {
    return json({ error: "Bad request" }, 400, origin);
  }

  const title = ((payload && payload.title) || "").trim();
  const details = ((payload && payload.body) || "").trim();

  if (title.length < 6)
    return json(
      { error: "Give your idea a clearer title (at least 6 characters)." },
      400,
      origin
    );
  if (title.length > 120)
    return json({ error: "That title is too long (120 characters max)." }, 400, origin);
  if (details.length > 4000)
    return json({ error: "That description is too long." }, 400, origin);

  const issueResponse = await gh("/repos/" + REPO + "/issues", session.token, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      title,
      body: (details || "_No extra detail provided._") + SIGNATURE
    })
  });

  if (issueResponse.status !== 201)
    return json({ error: "Couldn't create your request." }, 502, origin);

  const issue = await issueResponse.json();

  const botToken = env("ROADMAP_BOT_TOKEN");
  if (botToken && issue.number) {
    await gh(
      "/repos/" + REPO + "/issues/" + issue.number + "/labels",
      botToken,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ labels: ["roadmap"] })
      }
    );
  }

  return json(
    { number: issue.number, url: issue.html_url, title: issue.title },
    201,
    origin
  );
};

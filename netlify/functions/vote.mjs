/* POST /vote  { issue, action, reactionId? }  ->  { voted, reactionId? }

   A vote is a 👍 reaction on the issue, added or removed as the signed-in user.
   Any authenticated GitHub user can react to issues in a public repo, so no
   special permission is needed.

   action "add":    creates (or reuses) the reaction and returns its id.
   action "remove": deletes the reaction. If the browser didn't keep the id we
                    look it up from the issue's reaction list. */

import { json, preflight, sessionFrom, gh, REPO } from "./lib/shared.mjs";

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

  const number = parseInt(payload && payload.issue, 10);
  const action = payload && payload.action;
  if (!number || (action !== "add" && action !== "remove"))
    return json({ error: "Bad request" }, 400, origin);

  if (action === "add") {
    const response = await gh(
      "/repos/" + REPO + "/issues/" + number + "/reactions",
      session.token,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: "+1" })
      }
    );
    if (response.status !== 200 && response.status !== 201)
      return json({ error: "Couldn't record your vote" }, 502, origin);
    const reaction = await response.json();
    return json({ voted: true, reactionId: reaction.id }, 200, origin);
  }

  let reactionId = payload.reactionId;
  if (!reactionId) {
    const listResponse = await gh(
      "/repos/" + REPO + "/issues/" + number + "/reactions?content=%2B1&per_page=100",
      session.token
    );
    const list = await listResponse.json();
    const mine = Array.isArray(list)
      ? list.find(
          (reaction) =>
            reaction.content === "+1" &&
            reaction.user &&
            reaction.user.login === session.login
        )
      : null;
    if (!mine) return json({ voted: false }, 200, origin);
    reactionId = mine.id;
  }

  await gh(
    "/repos/" + REPO + "/issues/" + number + "/reactions/" + reactionId,
    session.token,
    { method: "DELETE" }
  );
  return json({ voted: false }, 200, origin);
};

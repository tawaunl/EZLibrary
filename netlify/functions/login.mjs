/* POST /login  { code }  ->  { session, user }

   Exchanges a GitHub OAuth "code" (from the browser redirect) for an access
   token, confirms who the token belongs to, then returns an encrypted session
   blob the browser can replay to /vote and /submit. The raw GitHub token and
   the OAuth client secret never leave the server. */

import { json, preflight, seal, env } from "./lib/shared.mjs";

export default async (request) => {
  const origin = request.headers.get("origin");
  if (request.method === "OPTIONS") return preflight(request);
  if (request.method !== "POST")
    return json({ error: "Method not allowed" }, 405, origin);

  let payload;
  try {
    payload = await request.json();
  } catch (error) {
    return json({ error: "Bad request" }, 400, origin);
  }

  const code = payload && payload.code;
  if (!code) return json({ error: "Missing authorization code" }, 400, origin);

  const clientId = env("GITHUB_CLIENT_ID");
  const clientSecret = env("GITHUB_CLIENT_SECRET");
  if (!clientId || !clientSecret)
    return json({ error: "Sign-in is not configured yet" }, 500, origin);

  const tokenResponse = await fetch(
    "https://github.com/login/oauth/access_token",
    {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({
        client_id: clientId,
        client_secret: clientSecret,
        code
      })
    }
  );
  const tokenData = await tokenResponse.json();
  const accessToken = tokenData && tokenData.access_token;
  if (!accessToken)
    return json(
      { error: tokenData.error_description || "Sign-in failed" },
      401,
      origin
    );

  const userResponse = await fetch("https://api.github.com/user", {
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: "Bearer " + accessToken,
      "User-Agent": "EZLibrary-Roadmap"
    }
  });
  const user = await userResponse.json();
  if (!user || !user.login)
    return json({ error: "Couldn't read your GitHub profile" }, 401, origin);

  const session = await seal({
    token: accessToken,
    login: user.login,
    at: Date.now()
  });

  return json(
    {
      session,
      user: {
        login: user.login,
        name: user.name || user.login,
        avatar_url: user.avatar_url
      }
    },
    200,
    origin
  );
};

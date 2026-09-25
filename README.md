# VOIDBLOOM co-op server

This small Node program runs **THE UNDERVAULT**, the online co-op mode for up to four
players. It uses [Colyseus](https://colyseus.io) and is set up for Render's **free** plan.

It does very little work on purpose. One player in each lobby (the **host**) runs the
real game in their browser: every enemy, bullet and boss. The server only:

- keeps the lobbies: the 4-letter join codes, the four seats, names, ready flags and who hosts
- passes game packets between the players without opening them
- hands the host role to someone else if the host leaves (8 seconds' grace, then it moves)
- keeps a dropped player's seat for 25 seconds so they can reconnect

Because it only forwards bytes, the free plan's small CPU can carry several full lobbies.

---

## Put it online (free, about 10 minutes)

You need a GitHub account and a Render account. Render doesn't ask for a credit card
for the free plan.

### 1. Put these files on GitHub

1. Go to <https://github.com/new>, name the repository `voidbloom-server`, and click
   **Create repository**.
2. Double-click **UPDATE SERVER.bat** in this folder. The first time, it asks for the
   address of that repository (it guesses, so usually just press Enter), then sends
   everything up. Every time after that it is one double-click and a few words about
   what changed.

   *If you'd rather do it by hand:* on the empty repo page click **uploading an existing
   file**, drag in `index.js`, `package.json`, `package-lock.json`, `render.yaml`,
   `.gitignore` and `README.md` — not `node_modules` — and click **Commit changes**.

### 2. Make the service on Render

1. Sign up at <https://render.com> with **Sign in with GitHub**.
2. In the dashboard, click **New +** → **Blueprint**, pick the `voidbloom-server` repo,
   and click **Apply**. Render reads `render.yaml` and sets everything up: free plan,
   Singapore region (the closest to Australia), `npm install`, `node index.js`, and a
   health check on `/health`.

   *If you'd rather click through it yourself:* **New +** → **Web Service** → pick the
   repo, then set
   Language **Node** · Build Command `npm install` · Start Command `node index.js` ·
   Instance Type **Free** · Region **Singapore** · Advanced → Health Check Path `/health`.
3. Wait until the service says **Live**. The first build takes 2–3 minutes.
4. Copy the address at the top of the service page. It looks like
   `https://voidbloom-server.onrender.com`. If that name was already taken, Render adds a
   few letters, like `https://voidbloom-server-x7k2.onrender.com`. Use whatever yours says.
5. Check it: open `https://YOUR-ADDRESS/health` in a browser. You should see
   `{"ok":"voidbloom","protocol":"undervault-1",...}`.

### 3. Point the game at it

Open `VOIDBLOOM.html` in a text editor (VS Code is fine) and search for
`MP_SERVER_URL`. Change the address inside the quotes to yours, with no `/` on the end:

```js
const MP_SERVER_URL = 'https://voidbloom-server-x7k2.onrender.com';
```

That's the only line to change. Save the file, then ship it as usual (the itch zip,
CrazyGames, and `UPDATE GAME.bat` for the desktop app).

**To try it before you edit anything:** open the game in a browser, press F12, and in the
Console run

```js
localStorage.setItem('voidbloom.server', 'https://YOUR-ADDRESS')
```

then reload. That copy of the game uses your server until you run
`localStorage.removeItem('voidbloom.server')`.

---

## What the free plan does

- **It would sleep, but it doesn't.** Render stops a free service after 15 idle minutes,
  and starting it again takes the better part of a minute — long enough for the gateway in
  front of it to give up and hand the player **error 524** instead of a lobby. So the
  server pings its own `/health` every 10 minutes (`AWAKE_MS`, see below). Any inbound
  request resets the idle timer, so it never sleeps and there is no cold start left to
  time out. The loading bar in the game still exists for the times it does have to start
  from cold — a deploy, a crash, a Render restart.
- **Hours:** 750 free hours a month. A month is at most 744 hours, so a server that is up
  the whole time still fits. **This only holds for one free service** — if you ever add a
  second one they share the 750 hours, and then one of them has to be allowed to sleep.
- **It stays awake while people play.** Messages from connected players count as
  activity too, so a lobby or a run is never cut off by the sleep timer.
- **Traffic:** the server compresses what it sends (`perMessageDeflate`), and a busy
  four-player run costs it about 20–30 kB/s — roughly **15 MB for a whole run**. Two
  players cost about a third of that. A free workspace includes **5 GB of outbound traffic
  a month**, so that is somewhere north of 300 four-player runs. If a month ever goes over,
  Render suspends the service until the next month rather than charging anything; the
  Billing page shows how much you have used.

## Sending a change up

**UPDATE SERVER.bat** — double-click it. It:

1. checks the files first: `index.js` is a real server and parses, `package.json` is valid
   JSON with a start script, and the protocol matches the one in `VOIDBLOOM.html`. A typo
   caught here saves three minutes of Render's build time.
2. shows you which files changed and asks what to call the change,
3. commits and pushes it to GitHub, which is what tells Render to redeploy,
4. **waits and proves it worked.** `/health` reports `sig`, a fingerprint of the exact
   `index.js` the server is running. The script works out the same fingerprint from the
   file on your disk and watches until the live server reports it. "It deployed" stops
   being something you hope.

If the push fails — no internet, GitHub asking for a sign-in — nothing is lost: the commit
sits here and the next run sends it.

### Settings you can change on Render

Render → your service → **Environment**. Both are optional.

| | |
|---|---|
| `AWAKE_MS` | how often the server pings itself, in milliseconds. Default `600000` (10 min), minimum 30000. Set it higher to let the server sleep again. |
| `PORT` | Render sets this itself. Don't. |

## Changing the netcode later

The game and the server both carry a protocol name, `undervault-1`. The server turns away
any game whose protocol doesn't match, and the game shows a clear "update" message
instead of breaking mid-run. If you ever change how the packets work, change **both**:

- `PROTOCOL` near the top of `index.js`
- `MP_PROTOCOL` in `VOIDBLOOM.html`

Push the server change to GitHub and Render redeploys it on its own (`autoDeployTrigger:
commit`).

## Run it on your own computer

```
npm install
npm start
```

It listens on `http://localhost:2567`. Point a copy of the game at it with
`localStorage.setItem('voidbloom.server', 'http://localhost:2567')` in the game's console.

## The desktop app

The desktop app locks down what the game can connect to. Its `main.js` allows
`https://*.onrender.com` and `wss://*.onrender.com`, so any Render address works. If you
ever host the server somewhere else, add that address to `connect-src` in
`desktop/main.js`.

## Endpoints

| | |
|---|---|
| `GET /health` | `{ ok: 'voidbloom', protocol, sig, up, rooms, players, cpu, mem }`. The game polls this while the server wakes up; `sig` fingerprints the running `index.js`, and `UPDATE SERVER.bat` uses it to prove a deploy landed. |
| `GET /` | a one-line "awake" message, so opening the address in a browser shows something |
| WebSocket | Colyseus matchmaking and the `undervault` room |

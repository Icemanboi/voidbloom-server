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
2. On the empty repo page, click **uploading an existing file**.
3. Drag in everything in this folder: `index.js`, `package.json`, `package-lock.json`,
   `render.yaml`, `.gitignore` and `README.md`. Don't upload a `node_modules` folder if
   you have one. Click **Commit changes**.

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

- **It sleeps.** After 15 minutes with nobody connected, Render stops the server. The
  next player to open MULTIPLAYER wakes it up, which takes about a minute. That's what the
  loading bar in the game shows, and it gets better at guessing the wait each time.
  Hovering over the MULTIPLAYER card for a moment starts the wake-up early.
- **It stays awake while people play.** Messages from connected players count as
  activity, so a lobby or a run never gets cut off by the sleep timer.
- **Hours:** 750 free hours a month. A month is at most 744 hours, so one service never
  runs out.
- **Traffic:** the server compresses what it sends (`perMessageDeflate`), and a busy
  four-player run costs it about 20–30 kB/s — roughly **15 MB for a whole run**. Two
  players cost about a third of that. A free workspace includes **5 GB of outbound traffic
  a month**, so that is somewhere north of 300 four-player runs. If a month ever goes over,
  Render suspends the service until the next month rather than charging anything; the
  Billing page shows how much you have used.

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
| `GET /health` | `{ ok: 'voidbloom', protocol, up, rooms, players }`. The game polls this while the server wakes up. |
| `GET /` | a one-line "awake" message, so opening the address in a browser shows something |
| WebSocket | Colyseus matchmaking and the `undervault` room |

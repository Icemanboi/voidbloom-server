/* =====================================================================
   VOIDBLOOM -- co-op server for THE UNDERVAULT
   ---------------------------------------------------------------------
   Colyseus 0.18 on one small Node process. Built for Render's free plan:
   0.1 CPU, and it goes to sleep after 15 minutes with nobody on it.

   The server does almost no game work on purpose. One player in each
   lobby -- the HOST -- runs the real game. Everyone else sends the host
   their ship, their hits and their pickups, and the host sends back what
   the enemies, bullets and bosses are doing. This process only:

     - keeps lobbies: codes, the four seats, names, ready flags, the host
     - relays game packets between players without opening them
     - hands the host role to someone else if the host leaves

   Relaying bytes it never decodes is what lets a 0.1-CPU box carry
   several full four-player lobbies at once.

   Endpoints
     GET /health   -> { ok: 'voidbloom', ... }   the game polls this while
                      the server wakes up, to drive its loading bar
     GET /         -> a one-line text page, so opening the URL in a
                      browser shows something friendly
     ws            -> Colyseus matchmaking + rooms (room name: 'undervault')
   ===================================================================== */
import { Server, Room, matchMaker } from '@colyseus/core';
import { WebSocketTransport } from '@colyseus/ws-transport';

const PORT = Number(process.env.PORT || 2567);
// the game refuses to play with a server that speaks a different protocol
const PROTOCOL = 'undervault-1';
const STARTED = Date.now();
const MAX_PLAYERS = 4;
const HOST_GRACE_S = 5;          // a host that drops gets this long to come back
const RECONNECT_S = 25;          // anyone else gets this long
const DIFFS = ['normal', 'hard', 'nightmare'];
const SKIN_RE = /^[a-z0-9_]{1,24}$/;

// four-letter codes, no 0/O/1/I so nobody misreads one over voice chat
const ALPHA = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function newCode(len) {
  let s = '';
  for (let i = 0; i < len; i++) s += ALPHA[(Math.random() * ALPHA.length) | 0];
  return s;
}
function cleanName(v) {
  const s = String(v || '').toUpperCase().replace(/[^A-Z0-9 _-]/g, '').trim().slice(0, 14);
  return s || 'WANDERER';
}

let liveRooms = 0, livePlayers = 0;

/* How hard this little box is working. A free instance gets a tenth of a CPU;
   if `cpu` sits near 10% of a core the relay is being throttled, and players
   feel that as lag. /health reports it so it can be checked from anywhere. */
let cpuPct = 0, lastCpu = process.cpuUsage(), lastCpuT = Date.now();
setInterval(() => {
  const c = process.cpuUsage(lastCpu), dt = Date.now() - lastCpuT;
  lastCpu = process.cpuUsage(); lastCpuT = Date.now();
  if (dt > 0) cpuPct = Math.round((c.user + c.system) / 10 / dt);
}, 5000).unref();

// a promise nobody caught should never take the whole lobby down with it
process.on('unhandledRejection', (e) => console.error('[voidbloom] unhandled rejection:', e && e.message || e));

class UndervaultRoom extends Room {
  maxClients = MAX_PLAYERS;
  // a relay should never be the thing that disconnects a player; this only
  // stops a broken client from flooding the box
  maxMessagesPerSecond = 400;

  async onCreate(options) {
    options = options || {};
    this.isPublic = !!options.public;
    // the room id IS the join code. Four letters, and five if four ever collide.
    let code = newCode(4);
    for (let i = 0; i < 20; i++) {
      const taken = await matchMaker.query({ roomId: code });
      if (!taken || !taken.length) break;
      code = newCode(i < 10 ? 4 : 5);
    }
    this.roomId = code;
    this.seats = new Map();        // sessionId -> seat
    this.hostId = null;
    this.phase = 'lobby';          // lobby | running
    this.diff = DIFFS.indexOf(options.diff) >= 0 ? options.diff : 'normal';
    this.runNo = 0;
    this.hostTimer = null;
    if (!this.isPublic) await this.setPrivate(true);
    await this.setMetadata({ public: this.isPublic, phase: 'lobby' });
    liveRooms++;

    // ------------------------------------------------------------ lobby
    this.onMessage('profile', (client, p) => {
      const s = this.seats.get(client.sessionId);
      if (!s || !p) return;
      if (p.name !== undefined) s.name = cleanName(p.name);
      if (typeof p.skin === 'string' && SKIN_RE.test(p.skin)) s.skin = p.skin;
      if (typeof p.pet === 'string' && SKIN_RE.test(p.pet)) s.pet = p.pet;
      this.sendLobby();
    });
    this.onMessage('ready', (client, v) => {
      const s = this.seats.get(client.sessionId);
      if (!s || this.phase !== 'lobby') return;
      s.ready = !!v;
      this.sendLobby();
    });
    this.onMessage('diff', (client, v) => {
      if (client.sessionId !== this.hostId || this.phase !== 'lobby') return;
      if (DIFFS.indexOf(v) < 0) return;
      this.diff = v;
      this.sendLobby();
    });
    this.onMessage('start', async (client) => {
      if (client.sessionId !== this.hostId || this.phase !== 'lobby') return;
      this.phase = 'running';
      this.runNo++;
      await this.lock();
      await this.setMetadata({ public: this.isPublic, phase: 'running' });
      const roster = [];
      for (const s of this.seats.values()) roster.push(this.seatInfo(s));
      this.broadcast('start', {
        run: this.runNo, diff: this.diff, seed: (Math.random() * 0x7fffffff) | 0,
        hostSlot: this.seatOf(this.hostId).slot, roster: roster
      });
      this.sendLobby();
    });
    // the host says the run is over (win or wipe): everyone is back in the lobby
    this.onMessage('end', async (client) => {
      if (client.sessionId !== this.hostId || this.phase !== 'running') return;
      await this.backToLobby();
    });
    // any player may pass a small JSON note to everyone (emotes, picks, revive
    // calls) -- sent on to the others untouched
    this.onMessage('note', (client, n) => {
      const s = this.seats.get(client.sessionId);
      if (!s) return;
      this.broadcast('note', { from: s.slot, n: n }, { except: client });
    });
    this.onMessage('ping', (client, t) => client.send('pong', t));

    // ------------------------------------------------------- game relays
    // host -> everyone else: the world (snapshots, spawns, bullets, kills)
    this.onMessageBytes('h', (client, bytes) => {
      if (client.sessionId !== this.hostId) return;
      this.broadcastBytes('h', bytes, { except: client });
    });
    // one player -> the host only: hits, pickups, picks
    this.onMessageBytes('c', (client, bytes) => {
      const s = this.seats.get(client.sessionId);
      const host = this.clientById(this.hostId);
      if (!s || !host || host === client) return;
      host.sendBytes('c' + s.slot, bytes);
    });
    // one player -> every other player: where they are, what they fired
    this.onMessageBytes('a', (client, bytes) => {
      const s = this.seats.get(client.sessionId);
      if (!s) return;
      this.broadcastBytes('a' + s.slot, bytes, { except: client });
    });
    // host -> one player: a full picture of the world, for a late arrival
    this.onMessageBytes('f', (client, bytes) => {
      if (client.sessionId !== this.hostId || !bytes || bytes.length < 2) return;
      const to = bytes[0];
      for (const s of this.seats.values()) {
        if (s.slot !== to) continue;
        const c = this.clientById(s.id);
        if (c) c.sendBytes('f', bytes.subarray(1));
      }
    });
  }

  onAuth(client, options) {
    if (!options || options.v !== PROTOCOL) {
      throw new Error('VERSION: this server runs ' + PROTOCOL + ' -- update the game');
    }
    if (this.phase !== 'lobby') throw new Error('RUNNING: that delve has already started');
    return true;
  }

  onJoin(client, options) {
    const used = new Set();
    for (const s of this.seats.values()) used.add(s.slot);
    let slot = 0;
    while (used.has(slot)) slot++;
    const seat = {
      id: client.sessionId, slot: slot,
      name: cleanName(options.name),
      skin: typeof options.skin === 'string' && SKIN_RE.test(options.skin) ? options.skin : 'seed',
      pet: typeof options.pet === 'string' && SKIN_RE.test(options.pet) ? options.pet : 'mote',
      ready: false, online: true
    };
    this.seats.set(client.sessionId, seat);
    if (!this.hostId || !this.seats.has(this.hostId)) this.hostId = client.sessionId;
    livePlayers++;
    client.send('welcome', { slot: slot, code: this.roomId, host: this.hostId === client.sessionId, public: this.isPublic, protocol: PROTOCOL });
    this.sendLobby();
  }

  // dropped without saying goodbye: hold the seat
  async onDrop(client) {
    const s = this.seats.get(client.sessionId);
    if (!s) return;
    s.online = false;
    this.broadcast('drop', { slot: s.slot });
    if (client.sessionId === this.hostId) {
      // the game stalls without a host; give it a moment, then hand it on
      clearTimeout(this.hostTimer);
      this.hostTimer = setTimeout(() => {
        if (this.seats.has(this.hostId) && !this.seats.get(this.hostId).online) this.migrateHost();
      }, HOST_GRACE_S * 1000);
    }
    this.sendLobby();
    try { await this.allowReconnection(client, RECONNECT_S); } catch (e) { /* onLeave follows */ }
  }

  onReconnect(client) {
    const s = this.seats.get(client.sessionId);
    if (!s) return;
    s.online = true;
    if (client.sessionId === this.hostId) clearTimeout(this.hostTimer);
    this.broadcast('back', { slot: s.slot });
    client.send('welcome', { slot: s.slot, code: this.roomId, host: this.hostId === client.sessionId, public: this.isPublic, protocol: PROTOCOL, rejoin: true });
    this.sendLobby();
  }

  async onLeave(client) {
    const s = this.seats.get(client.sessionId);
    if (!s) return;
    this.seats.delete(client.sessionId);
    livePlayers = Math.max(0, livePlayers - 1);
    this.broadcast('left', { slot: s.slot });
    if (client.sessionId === this.hostId) this.migrateHost();
    if (!this.seats.size) return;
    // a run with nobody left who is actually playing goes back to the lobby
    if (this.phase === 'running' && ![...this.seats.values()].some(x => x.online)) await this.backToLobby();
    this.sendLobby();
  }

  onDispose() { liveRooms = Math.max(0, liveRooms - 1); clearTimeout(this.hostTimer); }

  // ---------------------------------------------------------------- helpers
  migrateHost() {
    clearTimeout(this.hostTimer);
    let best = null;
    for (const s of this.seats.values()) {
      if (s.id === this.hostId) continue;
      if (!best || (s.online && !best.online) || (s.online === best.online && s.slot < best.slot)) best = s;
    }
    if (!best) { this.hostId = null; return; }
    this.hostId = best.id;
    this.broadcast('host', { slot: best.slot });
    this.sendLobby();
  }
  async backToLobby() {
    this.phase = 'lobby';
    for (const s of this.seats.values()) s.ready = false;
    await this.unlock();
    await this.setMetadata({ public: this.isPublic, phase: 'lobby' });
    this.broadcast('ended', { run: this.runNo });
    this.sendLobby();
  }
  seatOf(id) { return this.seats.get(id) || null; }
  clientById(id) { for (const c of this.clients) if (c.sessionId === id) return c; return null; }
  seatInfo(s) {
    return { slot: s.slot, name: s.name, skin: s.skin, pet: s.pet, ready: s.ready, online: s.online, host: s.id === this.hostId };
  }
  sendLobby() {
    const list = [];
    for (const s of this.seats.values()) list.push(this.seatInfo(s));
    list.sort((a, b) => a.slot - b.slot);
    this.broadcast('lobby', { code: this.roomId, public: this.isPublic, phase: this.phase, diff: this.diff, seats: list });
  }
}

const server = new Server({
  // the host's world packets can run to tens of kilobytes in a big boss fight;
  // the transport's own default (4 KB) would drop the host mid-fight
  transport: new WebSocketTransport({
    pingInterval: 5000, pingMaxRetries: 4, maxPayload: 512 * 1024,
/* Compress what goes out. The free plan counts outbound bytes, and a
       host's world packets are very like the one before them, so deflate with
       the window kept between messages roughly halves the traffic. Level 1 and
       a 512-byte floor keep the CPU cost small -- a free instance only gets a
       tenth of a core, and a stalled relay is felt by every player as lag. */
    perMessageDeflate: {
      zlibDeflateOptions: { level: 1, memLevel: 7 },
      serverMaxWindowBits: 13,
      threshold: 512,
      concurrencyLimit: 8
    }
  }),
  greet: false,
  express: (app) => {
    // the game is served from itch.io, CrazyGames and the desktop app, so the
    // wake-up poll comes cross-origin
    app.use((req, res, next) => {
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
      if (req.method === 'OPTIONS') { res.statusCode = 204; return res.end(); }
      next();
    });
    app.get('/health', (req, res) => {
      res.setHeader('Cache-Control', 'no-store');
      res.json({ ok: 'voidbloom', protocol: PROTOCOL, up: Math.round((Date.now() - STARTED) / 1000), rooms: liveRooms, players: livePlayers,
        cpu: cpuPct, mem: Math.round(process.memoryUsage().rss / 1048576) });
    });
    app.get('/', (req, res) => {
      res.type('text/plain').send('VOIDBLOOM co-op server is awake. Rooms: ' + liveRooms + ', players: ' + livePlayers +
        '. Up ' + Math.round((Date.now() - STARTED) / 60000) + ' min, cpu ' + cpuPct + '% of a core, memory ' + Math.round(process.memoryUsage().rss / 1048576) + ' MB.');
    });
  }
});

// one room type; public (quick play) and private (code) lobbies never mix
server.define('undervault', UndervaultRoom).filterBy(['public']);

server.listen(PORT).then(() => {
  console.log('[voidbloom] co-op server listening on :' + PORT + ' (' + PROTOCOL + ')');
});

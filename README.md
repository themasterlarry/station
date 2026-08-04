# Station

A personal system built out of separate pages. Put every file in one folder and open `index.html`.

## The pages

| File | Code | What it holds |
|---|---|---|
| `index.html` | `//` | Day sheet — what needs you today, pulled from every other page |
| `tasks.html` | `TK` | Lists, priorities, due dates, repeating tasks |
| `calendar.html` | `CL` | Month grid and day agenda |
| `contacts.html` | `CT` | People, and everything each one connects to |
| `notes.html` | `NT` | Notes with tags and pinning |
| `habits.html` | `HB` | Daily check-off and streaks |
| `items.html` | `TH` | What you lent out and what you borrowed |
| `money.html` | `$$` | The full cash ledger — accounts, entries, tickets |
| `vault.html` | `PW` | Encrypted password vault |

Every page carries the same rail, the same search (`/` on a keyboard), and the same backup button. They are separate documents, not tabs — each one loads on its own and can be bookmarked or pinned to a home screen by itself.

## How they share data

Three storage keys hold everything:

- `hub:v1` — tasks, events, contacts, notes, habits, items
- `cashledger:v1` — accounts, entries, tickets
- `vault:v1` — the password vault, encrypted (see below)

Contacts live in one ID space across both. Add someone on the contacts page and their name is available in the ledger; log money with a new name in the ledger and they appear in contacts with their balance. Same for items you lend and events you invite people to.

Because each page loads data when it opens, changes made on one page show up on the next page you visit. If you leave two pages open in different tabs, refresh the second one after editing the first.

## How the vault works

The vault is the one module that does not store readable data.

- Your master password is stretched into a 256-bit key with **PBKDF2-SHA256, 600,000 rounds**, against a random 16-byte salt.
- Entries are encrypted as one blob with **AES-256-GCM** and a fresh random 12-byte IV on every save. GCM's auth tag means a tampered or truncated blob fails to open rather than decrypting into garbage.
- What lands in storage is: salt, iteration count, IV, ciphertext. Nothing else. Not the master password, not the derived key, not entry titles.
- The key exists only in a JavaScript variable. It is gone when the page unloads — which, since every module is its own page, means **clicking any nav link locks the vault**. It also auto-locks after 5 minutes idle.
- Copied passwords clear from the clipboard after 20 seconds.
- Random characters come from `crypto.getRandomValues`, never `Math.random`.

**There is no recovery.** No reset link, no backdoor, no support. Forget the master password and the entries are unreadable forever. Write it on paper and put it somewhere you'd keep a passport.

Backups contain the vault still encrypted, so a stolen backup file is useless without the master password — but restoring one requires the password that was in force when it was saved.

### What this does not protect against

Encryption at rest is one layer. It does not stop malware or a bad browser extension reading the key while the vault is unlocked, and it does not stop someone who already knows your master password. A dedicated manager also gives you autofill that refuses to type your bank password into a lookalike phishing domain, plus breach monitoring — neither of which this has. Keep email and banking in Bitwarden or KeePassXC; use this for everything else.

## Moving it to a server

All storage goes through one object at the top of every page's script:

```js
var DB = {
  ok: !!(window.storage && window.storage.get),
  async get(k){ ... },
  async set(k,v){ ... }
};
```

That block is byte-identical in all eight files. Replace it everywhere with:

```js
var DB = {
  ok: true,
  async get(k){
    const r = await fetch(`/api/kv/${k}`);
    return r.ok ? r.json() : null;
  },
  async set(k, v){
    await fetch(`/api/kv/${k}`, {
      method: 'PUT',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify(v)
    });
    return true;
  }
};
```

Better: cut everything between the `STATION CORE` comment and the first `function pageHead` out of all eight files, save it as `core.js`, and load it with `<script src="core.js"></script>` before each page's own script. That is exactly how these files were assembled, so the split is clean. Do it once on the server and there is one copy of the shared code instead of eight.

## Proxmox setup

One unprivileged Debian 12 LXC container. 1 core, 512 MB RAM, 8 GB disk is plenty — this is a handful of JSON blobs, not a database workload.

```
LXC: station
├── Caddy          → TLS + serves the folder + proxies /api
├── Node/Express   → the KV API
└── SQLite         → /var/lib/station/station.db
```

Four routes and one table:

```
GET    /api/kv/:key
PUT    /api/kv/:key
GET    /api/keys
DELETE /api/kv/:key
```

```sql
CREATE TABLE kv (
  key     TEXT PRIMARY KEY,
  value   TEXT NOT NULL,
  updated INTEGER NOT NULL
);
```

**Access.** Reach it over Tailscale or WireGuard rather than exposing it. If you do put it on a public address, put Authelia or Caddy basic auth in front — a ledger with no auth on the open internet will get found.

**Backups.** Proxmox container snapshots, plus a nightly copy of `station.db` off the host. The in-app "Download everything" button is a third copy you control by hand.

## Adding a module later

1. Copy any small page — `habits.html` is the simplest — and rename it.
2. Change `var PAGE="..."` to the new id.
3. Add a row to `MODULES` in the core (all eight files, or `core.js` once you have split it out).
4. Rewrite `pageHead`, `pageRender`, and optionally `pageAction` / `pageBoot`. Those four functions are the entire contract between a page and the shell.
5. Store the module's data on `H` under a new array, and add a line to `migrateH()` so old saves don't break.

Worth building next, roughly in order of how much use they'd get:

1. **Recurring bills** — amount, due day, method, paid mark per month. Feeds the day sheet and pre-fills a ledger entry when you mark one paid.
2. **Documents** — scans of your lease, ID, insurance. Needs real file storage, so build it after the server exists.
3. **Places** — addresses that matter, tied to contacts and to event locations.
4. **Vehicle log** — mileage, repairs, what you have sunk into it. Ties into the ledger.
5. **Health log** — appointments, what happened, what to ask next time.

## Conventions

- **Two-letter module codes.** They appear on the day sheet, in search results, and in the rail so you can tell at a glance where something came from.
- **Money as integer cents.** Never floats.
- **Dates as `YYYY-MM-DD`, times as `HH:MM`.** String comparison sorts correctly and there is no timezone mess.
- **Every record gets a random `id`.** Contacts share an ID space across modules — that is what makes the cross-links work.
- **The vault never leaves the vault page.** No other module reads `vault:v1` in plaintext, and the core only ever passes the encrypted blob through to backups. Keep it that way.
- **A `version` field plus a `migrate()` on load.** It is what let the Capital One accounts rename themselves to Checking and Savings without losing data.

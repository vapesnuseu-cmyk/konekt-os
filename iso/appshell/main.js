// =============================================================================
// KONEKT OS — the app shell.
//
// Every KONEKT product is a real application on this system: its own window,
// its own place in the window list. Not a panel inside a page. This is the same
// shape Slack, Spotify and Notion ship — a Chromium runtime around the product
// — except the runtime here is the one KONEKT BROWSER already vendors, so
// nothing extra is downloaded.
//
//   electron /opt/konekt-apps/shell --id=konekt --url=https://… --title=KONEKT
//
// One session, shared. Every product window uses the same storage partition, so
// the KONEKT sign-in is one sign-in: authenticate once and every application is
// already signed in, including the desktop itself, which does its own KONEKT
// login through here (--sso) precisely so the session lands in the same place.
// =============================================================================
const { app, BrowserWindow, session, shell, Menu } = require('electron');
const http = require('http');
const path = require('path');

function arg(name, fallback) {
  const hit = process.argv.find(a => a.startsWith('--' + name + '='));
  return hit ? hit.slice(name.length + 3) : fallback;
}
const has = name => process.argv.includes('--' + name);

const APP_ID = arg('id', 'konekt-app');
const APP_URL = arg('url', 'https://konekt-os.vercel.app/');
const APP_TITLE = arg('title', 'KONEKT');
// The product as downloaded into this machine, served back over loopback. The
// live deployment is tried first so the application is never out of date; this
// is what it falls back to when there is no network, and it is a whole copy of
// the product, not a placeholder.
const LOCAL_URL = arg('offline-url', '');
const OFFLINE = path.join(__dirname, 'offline.html');

// The one session every KONEKT application shares.
const PARTITION = 'persist:konekt';

// The desktop's own service, and the address KONEKT SSO comes home to.
const SERVICE = 'http://127.0.0.1:8923';
const REDIRECT = 'http://localhost:8923/';

// Where a link is allowed to stay inside the application instead of being
// handed to KONEKT BROWSER. The sign-in provider has to be on this list or the
// login popup would leave for another browser mid-flow and never come back.
const KONEKT_HOSTS = [
  'konekt-sso.vercel.app',
  'konekt-tawny.vercel.app',
  'konekt-kouch.vercel.app',
  'lastochka-studio.vercel.app',
  'konekt-browser.vercel.app',
];
function isKonekt(url) {
  try { return KONEKT_HOSTS.includes(new URL(url).hostname); } catch (e) { return false; }
}

function tellService(pathname, payload) {
  return new Promise(resolve => {
    const body = Buffer.from(JSON.stringify(payload || {}), 'utf8');
    const req = http.request(
      SERVICE + pathname,
      { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': body.length } },
      res => { res.resume(); res.on('end', resolve); }
    );
    req.on('error', resolve);
    req.end(body);
  });
}

// ---------------------------------------------------------------- sign-in
// The desktop cannot sign in for itself: its own browser profile is not the one
// the applications use, so a session established there would leave every
// application signed out. So it sends the authorize URL here, this window walks
// the flow in the shared session, and the code goes back over the service.
function signIn() {
  const win = new BrowserWindow({
    width: 480, height: 640, backgroundColor: '#000000',
    title: 'KONEKT', autoHideMenuBar: true,
    webPreferences: { partition: PARTITION, contextIsolation: true, nodeIntegration: false },
  });
  Menu.setApplicationMenu(null);

  let settled = false;
  const finish = url => {
    if (settled) return true;
    if (!url || url.indexOf(REDIRECT) !== 0) return false;
    settled = true;
    let q;
    try { q = new URL(url).searchParams; } catch (e) { q = new URLSearchParams(); }
    tellService('/api/sso/code', {
      code: q.get('code') || '',
      state: q.get('state') || '',
      error: q.get('error') || '',
    }).then(() => { if (!win.isDestroyed()) win.destroy(); });
    return true;
  };

  // Catch the redirect before it loads: it points at the desktop itself, and
  // loading it here would open a second copy of the desktop in this window.
  win.webContents.on('will-redirect', (e, url) => { if (finish(url)) e.preventDefault(); });
  win.webContents.on('will-navigate', (e, url) => { if (finish(url)) e.preventDefault(); });

  win.on('closed', () => {
    if (!settled) tellService('/api/sso/code', { error: 'cancelled' }).then(() => app.quit());
    else app.quit();
  });

  win.loadURL(APP_URL);
}

// Signing out of the desktop signs out the applications, because there is only
// one session to sign out of. Loading the provider's own logout does it.
function signOut() {
  const win = new BrowserWindow({
    show: false,
    webPreferences: { partition: PARTITION, contextIsolation: true, nodeIntegration: false },
  });
  const done = () => {
    session.fromPartition(PARTITION).clearStorageData({ storages: ['cookies'] })
      .catch(() => {})
      .then(() => { if (!win.isDestroyed()) win.destroy(); app.quit(); });
  };
  win.webContents.once('did-finish-load', done);
  win.webContents.once('did-fail-load', done);
  setTimeout(done, 8000);
  win.loadURL(APP_URL);
}

// ---------------------------------------------------------------- a product
function openProduct() {
  const win = new BrowserWindow({
    width: 1180,
    height: 760,
    minWidth: 420,
    minHeight: 360,
    backgroundColor: '#000000',
    title: APP_TITLE,
    autoHideMenuBar: true,
    webPreferences: {
      partition: PARTITION,
      contextIsolation: true,
      nodeIntegration: false,
      spellcheck: false,
    },
  });
  Menu.setApplicationMenu(null);

  win.loadURL(APP_URL);
  win.on('page-title-updated', e => e.preventDefault());   // keep the product's name

  // A sign-in popup belongs to the flow and stays here, in the shared session.
  // Anything else is a link out, and links out open in KONEKT BROWSER.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (isKonekt(url)) {
      return {
        action: 'allow',
        overrideBrowserWindowOptions: {
          width: 480, height: 640, backgroundColor: '#000000', autoHideMenuBar: true,
          webPreferences: { partition: PARTITION, contextIsolation: true, nodeIntegration: false },
        },
      };
    }
    shell.openExternal(url);
    return { action: 'deny' };
  });

  // Alt+F4 closes this application and nothing else. The window manager used to
  // own this key, but a window manager binding closes whatever has focus - and
  // on the desktop that was the desktop, which took the whole session with it.
  win.webContents.on('before-input-event', (e, input) => {
    if (input.type === 'keyDown' && input.alt && input.key === 'F4') {
      e.preventDefault();
      win.close();
    }
  });

  let triedLocal = false;
  win.webContents.on('did-fail-load', (_e, code, desc, url, isMainFrame) => {
    if (!isMainFrame || code === -3) return;
    if (LOCAL_URL && !triedLocal) {
      triedLocal = true;                       // the copy that lives on this machine
      win.loadURL(LOCAL_URL);
      return;
    }
    win.loadFile(OFFLINE, { query: { title: APP_TITLE, url: APP_URL, desc: desc || String(code) } });
  });

  return win;
}

// ---------------------------------------------------------------- start
// Note there is no single-instance lock here. Electron's is keyed on the user
// data directory, and every product deliberately shares one so that they share
// a session — a lock would let the first application open and turn every one
// after it into a no-op. Keeping one window per product is the service's job,
// which knows which of them it has already started.
app.on('window-all-closed', () => app.quit());

if (has('sso')) {
  app.whenReady().then(signIn);
} else if (has('sso-logout')) {
  app.whenReady().then(signOut);
} else {
  app.whenReady().then(openProduct);
}

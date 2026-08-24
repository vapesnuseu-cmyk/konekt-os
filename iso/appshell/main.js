// =============================================================================
// KONEKT OS — the app shell.
//
// Every KONEKT product is a real application on this system: its own window,
// its own persistent session, its own place in the window list. Not a panel
// inside a page. This is the same shape Slack, Spotify and Notion ship — a
// Chromium runtime around the product — except the runtime here is the one
// KONEKT BROWSER already vendors, so nothing extra is downloaded.
//
//   electron /opt/konekt-apps/shell --id=konekt --url=https://… --title=KONEKT
// =============================================================================
const { app, BrowserWindow, shell, Menu } = require('electron');
const path = require('path');

function arg(name, fallback) {
  const hit = process.argv.find(a => a.startsWith('--' + name + '='));
  return hit ? hit.slice(name.length + 3) : fallback;
}

const APP_ID = arg('id', 'konekt-app');
const APP_URL = arg('url', 'https://konekt-os.vercel.app/');
const APP_TITLE = arg('title', 'KONEKT');
const OFFLINE = path.join(__dirname, 'offline.html');

// one instance per product: launching again raises the window you already have
if (!app.requestSingleInstanceLock({ id: APP_ID })) {
  app.quit();
} else {
  let win = null;

  app.on('second-instance', () => {
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });

  function create() {
    win = new BrowserWindow({
      width: 1180,
      height: 760,
      minWidth: 420,
      minHeight: 360,
      backgroundColor: '#000000',
      title: APP_TITLE,
      autoHideMenuBar: true,
      webPreferences: {
        // each product keeps its own cookies and storage, so signing into one
        // does not sign you into another by accident
        partition: 'persist:konekt-app-' + APP_ID,
        contextIsolation: true,
        nodeIntegration: false,
        spellcheck: false,
      },
    });
    Menu.setApplicationMenu(null);

    win.loadURL(APP_URL);
    win.on('page-title-updated', e => e.preventDefault());   // keep the product's name
    win.on('closed', () => { win = null; });

    // links that leave the product open in KONEKT BROWSER, not in here
    win.webContents.setWindowOpenHandler(({ url }) => {
      shell.openExternal(url);
      return { action: 'deny' };
    });

    win.webContents.on('did-fail-load', (_e, code, desc, url, isMainFrame) => {
      if (isMainFrame && code !== -3) {
        win.loadFile(OFFLINE, { query: { title: APP_TITLE, url: APP_URL, desc: desc || String(code) } });
      }
    });
  }

  app.whenReady().then(create);
  app.on('window-all-closed', () => app.quit());
}

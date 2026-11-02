// Dardasha for Windows: the web app in its own window, so it is always as new as the web.
const { app, BrowserWindow, desktopCapturer, session, shell } = require('electron');
const path = require('path');

const APP_URL = 'https://abdallah4f7.github.io/dardasha/app/';
// Sign-in pages have to stay in the window so the login comes back to the app.
const INSIDE = [/^https:\/\/abdallah4f7\.github\.io\/dardasha\//, /^https:\/\/accounts\.google\.com\//, /\.supabase\.co\//];

let win;

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (!win) return;
    if (win.isMinimized()) win.restore();
    win.focus();
  });
  app.whenReady().then(start);
  app.on('window-all-closed', () => app.quit());
}

function start() {
  app.setAppUserModelId('com.abdallah4f7.dardasha');
  const ses = session.defaultSession;
  // Google refuses to sign in from browsers that call themselves Electron.
  ses.setUserAgent(ses.getUserAgent().replace(/\s(Electron|dardasha|Dardasha)\/\S+/g, ''));
  // Microphone, camera and notifications for calls and messages.
  ses.setPermissionRequestHandler((_wc, permission, callback) => {
    callback(['media', 'notifications', 'clipboard-read', 'clipboard-sanitized-write', 'fullscreen', 'display-capture'].includes(permission));
  });
  // Screen sharing in a call shares the whole main screen.
  ses.setDisplayMediaRequestHandler(async (_request, callback) => {
    const [screen] = await desktopCapturer.getSources({ types: ['screen'] });
    callback(screen ? { video: screen } : {});
  });

  win = new BrowserWindow({
    width: 1100,
    height: 760,
    minWidth: 380,
    minHeight: 500,
    title: 'دردشة',
    icon: path.join(__dirname, 'build', 'icon.png'),
    autoHideMenuBar: true,
    backgroundColor: '#0e1222',
  });
  win.removeMenu();

  // Other links (YouTube, files…) open in the normal browser.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (INSIDE.some((r) => r.test(url))) return { action: 'allow' };
    shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    if (INSIDE.some((r) => r.test(url))) return;
    e.preventDefault();
    shell.openExternal(url);
  });

  win.loadURL(APP_URL);
}

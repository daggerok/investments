/// <reference types="bun" />

/**
 * @file Investments shell
 * One page with a tab per investment app. Every app is the real, unchanged
 * application of its own repo (ETFs hub, Stocks) shown in a frame, so each
 * keeps all of its functionality, its URL parameters and its saved state.
 *
 * Where the apps live (same rule as the ETFs hub feeds):
 *  - on github.io, or with ?api=remote: their GitHub Pages sites
 *  - anywhere else (`bun run serve`): ./ETFs/ and ./Stocks/ served by
 *    scripts/serve.ts from the cloned repos next to this one
 *  - ?api=local forces the local folders; the ?api parameter is passed on to the apps
 *
 * Opened apps stay loaded in hidden frames, so switching tabs keeps their state.
 * One theme for all: toggling it inside an app switches the shell and, when
 * shown, every other app (same origin only; cross-origin frames keep their own).
 */

type AppId = 'etfs' | 'stocks';
type App = { id: AppId; repo: string; themeKey: string };

const APPS: App[] = [
  { id: 'etfs', repo: 'ETFs', themeKey: 'etf-hub-theme' },
  { id: 'stocks', repo: 'Stocks', themeKey: 'stocks-theme' },
];
const TAB_KEY = 'investments-tab';
const THEME_KEY = 'investments-theme';
const GITHUB_PAGES_ORIGIN = 'https://daggerok.github.io/';

function byId(id: string): any {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} is missing in index.html`);
  return el;
}

function lsGet(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}

function lsSet(key: string, value: string): void {
  try { localStorage.setItem(key, value); } catch { /* quota, private mode or blocked storage */ }
}

function resolveApiMode(): 'remote' | 'local' {
  const forced = new URLSearchParams(location.search).get('api');
  if (forced === 'remote' || forced === 'local') return forced;
  return /(^|\.)github\.io$/i.test(location.hostname) ? 'remote' : 'local';
}

const API_MODE = resolveApiMode();
const API_PARAM = new URLSearchParams(location.search).get('api');

function appUrl(app: App): string {
  const search = API_PARAM ? `?api=${encodeURIComponent(API_PARAM)}` : '';
  return API_MODE === 'remote' ? `${GITHUB_PAGES_ORIGIN}${app.repo}/${search}` : `./${app.repo}/${search}`;
}

const el = {
  tabs: byId('app-tabs'),
  openApp: byId('open-app'),
  apiMode: byId('api-mode'),
  frames: Object.fromEntries(APPS.map(app => [app.id, byId(`frame-${app.id}`)])),
  buttons: Object.fromEntries(APPS.map(app => [app.id, byId(`tab-${app.id}`)])),
};

if (API_PARAM) {
  el.apiMode.textContent = API_MODE === 'remote' ? 'remote (github.io)' : 'local';
  el.apiMode.hidden = false;
}

// ---------------------------------------------------------------------------
// Theme: the shell follows the last toggle of any app and hands it to the others
// ---------------------------------------------------------------------------

function shellDark(): boolean {
  return document.documentElement.classList.contains('dark');
}

function applyShellTheme(dark: boolean): void {
  document.documentElement.classList.toggle('dark', dark);
  document.documentElement.style.backgroundColor = dark ? '#020617' : '#f8fafc';
  lsSet(THEME_KEY, dark ? 'dark' : 'light');
}

/** The frame's document when it is same-origin and loaded, otherwise null. */
function frameDocument(app: App): Document | null {
  try {
    const doc = el.frames[app.id].contentDocument;
    return doc && doc.readyState !== 'loading' && doc.getElementById('theme-toggle') ? doc : null;
  } catch {
    return null;
  }
}

/** Brings a loaded app to the shell theme with the app's own toggle, so its state stays consistent. */
function syncAppTheme(app: App): void {
  const doc = frameDocument(app);
  if (!doc) return;
  if (doc.documentElement.classList.contains('dark') !== shellDark()) doc.getElementById('theme-toggle')?.click();
}

// an app toggled its theme: the storage event reaches every other same-origin document, the shell included
window.addEventListener('storage', event => {
  const app = APPS.find(candidate => candidate.themeKey === event.key);
  if (!app || (event.newValue !== 'dark' && event.newValue !== 'light')) return;
  const dark = event.newValue === 'dark';
  if (dark !== shellDark()) applyShellTheme(dark);
});

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function isAppId(value: string | null): value is AppId {
  return APPS.some(app => app.id === value);
}

let activeId: AppId | null = null;

function activate(id: AppId): void {
  const app = APPS.find(candidate => candidate.id === id) || APPS[0];
  activeId = app.id;
  lsSet(TAB_KEY, app.id);
  const frame = el.frames[app.id];
  if (!frame.getAttribute('src')) {
    // first open: the app reads its theme key while it boots, so it starts in the shell theme
    lsSet(app.themeKey, shellDark() ? 'dark' : 'light');
    frame.addEventListener('load', () => { if (activeId === app.id) syncAppTheme(app); });
    frame.setAttribute('src', appUrl(app));
  }
  for (const other of APPS) {
    const selected = other.id === app.id;
    el.frames[other.id].hidden = !selected;
    el.buttons[other.id].setAttribute('aria-selected', String(selected));
    el.buttons[other.id].tabIndex = selected ? 0 : -1;
  }
  syncAppTheme(app);
  el.openApp.href = new URL(appUrl(app), location.href).href;
  document.title = `${el.buttons[app.id].textContent} - Investments`;
}

function fromHash(): AppId | null {
  const id = location.hash.replace(/^#/, '').toLowerCase();
  return isAppId(id) ? id : null;
}

el.tabs.addEventListener('click', (event: any) => {
  const button = event.target.closest('[data-app]');
  if (button && isAppId(button.dataset.app)) location.hash = button.dataset.app;
});

el.tabs.addEventListener('keydown', (event: any) => {
  if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
  const index = APPS.findIndex(app => app.id === activeId);
  const next = APPS[(index + (event.key === 'ArrowRight' ? 1 : APPS.length - 1)) % APPS.length];
  location.hash = next.id;
  el.buttons[next.id].focus();
  event.preventDefault();
});

window.addEventListener('hashchange', () => {
  const id = fromHash();
  if (id && id !== activeId) activate(id);
});

const saved = lsGet(TAB_KEY);
activate(fromHash() || (isAppId(saved) ? saved : 'etfs'));

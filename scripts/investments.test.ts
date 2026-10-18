/// <reference types="bun" />
import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { resolveRequest } from './serve';

const read = (path: string) => readFileSync(new URL(path, import.meta.url), 'utf8');
const html = read('../src/index.html');
const main = read('../src/main.ts');
const repos = (script: string) => (read(script).match(/^REPOS=\(([^)]*)\)/m)?.[1] ?? '').split(/\s+/).filter(Boolean);

describe('shell page', () => {
  test('every element main.ts reads by id exists in index.html', () => {
    const wanted = [...new Set([...main.matchAll(/\bbyId\('([^']+)'\)/g)].map((m) => m[1]))];
    for (const app of ['etfs', 'stocks']) wanted.push(`frame-${app}`, `tab-${app}`);
    expect(wanted.length).toBeGreaterThan(4);
    expect(wanted.filter((id) => !html.includes(`id="${id}"`))).toEqual([]);
  });

  test('every app has a tab and a frame, and the theme keys are the ones the apps use', () => {
    for (const [id, key] of [['etfs', 'etf-hub-theme'], ['stocks', 'stocks-theme']]) {
      expect(html).toContain(`data-app="${id}"`);
      expect(main).toContain(`themeKey: '${key}'`);
      expect(html).toContain(`localStorage.getItem('${key}')`);
    }
  });
});

describe('scripts', () => {
  test('install.sh and clean.sh know the same repos: the ETFs hub, Stocks and 29 brands', () => {
    const installed = repos('./install.sh');
    expect(installed).toEqual(repos('./clean.sh'));
    expect(installed.slice(0, 2)).toEqual(['ETFs', 'Stocks']);
    expect(installed.length).toBe(31);
    expect(new Set(installed.map((repo) => repo.toLowerCase())).size).toBe(31);
  });
});

describe('serve.ts resolveRequest', () => {
  let root = '';
  const file = (path: string) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), path);
  };

  beforeAll(() => {
    root = mkdtempSync(join(tmpdir(), 'investments-serve-'));
    for (const path of [
      'dist/index.html', 'dist/main.js',
      'ETFs/dist/index.html', 'ETFs/dist/ETFs.js',
      'AAM/api/aam/index.json', 'AAM/README.md',
      'Stocks/dist/index.html', 'Stocks/api/stocks/index.json',
    ]) file(path);
  });
  afterAll(() => rmSync(root, { recursive: true, force: true }));

  const at = (path: string) => ({ file: join(root, path) });

  test('the shell is served from dist', () => {
    expect(resolveRequest(root, '/')).toEqual(at('dist/index.html'));
    expect(resolveRequest(root, '/main.js')).toEqual(at('dist/main.js'));
  });

  test('the apps are served from their own dist, and need the trailing slash', () => {
    expect(resolveRequest(root, '/ETFs/')).toEqual(at('ETFs/dist/index.html'));
    expect(resolveRequest(root, '/ETFs/ETFs.js')).toEqual(at('ETFs/dist/ETFs.js'));
    expect(resolveRequest(root, '/Stocks/')).toEqual(at('Stocks/dist/index.html'));
    expect(resolveRequest(root, '/ETFs', '?api=local')).toEqual({ redirect: '/ETFs/?api=local' });
  });

  test('brand feeds are read from the brand folders next to the hub, the Stocks feed from Stocks/api', () => {
    expect(resolveRequest(root, '/ETFs/AAM/api/aam/index.json')).toEqual(at('AAM/api/aam/index.json'));
    expect(resolveRequest(root, '/Stocks/api/stocks/index.json')).toEqual(at('Stocks/api/stocks/index.json'));
  });

  test('a missing brand or file is a 404, so the apps fall back to GitHub Pages; only api/ of a brand is exposed', () => {
    expect(resolveRequest(root, '/ETFs/Tema/api/tema/index.json')).toBeNull();
    expect(resolveRequest(root, '/ETFs/AAM/README.md')).toBeNull();
    expect(resolveRequest(root, '/Stocks/api/stocks/missing.json')).toBeNull();
  });

  test('an app that is not built is sent to its GitHub Pages site', () => {
    rmSync(join(root, 'Stocks/dist'), { recursive: true });
    expect(resolveRequest(root, '/Stocks/', '?api=remote')).toEqual({ redirect: 'https://daggerok.github.io/Stocks/?api=remote' });
    expect(resolveRequest(root, '/Stocks/api/stocks/index.json')).toEqual(at('Stocks/api/stocks/index.json'));
  });

  test('paths outside the folder are refused', () => {
    for (const path of ['/../etc/passwd', '/%2e%2e/etc/passwd', '/ETFs/../../x', '/a%5c..%5cb', '/%E0%A4%A']) expect(resolveRequest(root, path)).toBeNull();
  });
});

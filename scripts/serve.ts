#!/usr/bin/env bun
/// <reference types="bun" />
/**
 * Local server of the investments app: one origin for the shell and every app, read straight from the cloned repos.
 *
 *   /                          -> dist/                      (the shell, `bun run build`)
 *   /ETFs/<Brand>/api/**       -> <Brand>/api/**             (the hub reads ./<Brand>/api/<slug>/ next to its page)
 *   /ETFs/**                   -> ETFs/dist/**               (`bun run build-apps`)
 *   /Stocks/api/**             -> Stocks/api/**              (always the current feed, no copy into dist needed)
 *   /Stocks/**                 -> Stocks/dist/**
 *
 * An app that is not cloned or not built is redirected to its GitHub Pages site; a missing brand or Stocks feed
 * is a 404, which the apps already answer by falling back to GitHub Pages.
 *
 * Usage: bun scripts/serve.ts [--watch]     PORT=1234 by default
 *   --watch rebuilds the shell, ETFs and Stocks with `parcel watch` on every change (reload the page to see it)
 */
import { existsSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';

export const APP_REPOS = ['ETFs', 'Stocks'];
const GITHUB_PAGES_ORIGIN = 'https://daggerok.github.io/';

export type Resolved = { file: string } | { redirect: string } | null;

function isFile(path: string): boolean {
  try { return statSync(path).isFile(); } catch { return false; }
}

function isDir(path: string): boolean {
  try { return statSync(path).isDirectory(); } catch { return false; }
}

/** Maps a request path to a file of the workspace root, a redirect, or null (404). */
export function resolveRequest(root: string, pathname: string, search = ''): Resolved {
  let path: string;
  try { path = decodeURIComponent(pathname); } catch { return null; }
  if (path.includes('\0') || path.includes('\\')) return null;
  const parts = path.split('/').filter(Boolean);
  if (parts.some(part => part === '.' || part === '..')) return null;

  const [first, second, third] = parts;
  let base = join(root, 'dist');
  let rest = parts;
  if (first !== undefined && APP_REPOS.includes(first)) {
    // the apps read their data relative to the page: /ETFs needs the slash to resolve ./<Brand>/api under /ETFs/
    if (parts.length === 1 && !pathname.endsWith('/')) return { redirect: `/${first}/${search}` };
    if (first === 'ETFs' && second && third === 'api' && !APP_REPOS.includes(second) && isDir(join(root, second, 'api'))) {
      base = root;
      rest = parts.slice(1);
    } else if (first === 'Stocks' && second === 'api') {
      base = join(root, 'Stocks');
      rest = parts.slice(1);
    } else {
      if (!isFile(join(root, first, 'dist', 'index.html'))) return { redirect: `${GITHUB_PAGES_ORIGIN}${parts.join('/')}${path.endsWith('/') ? '/' : ''}${search}` };
      base = join(root, first, 'dist');
      rest = parts.slice(1);
    }
  }
  let file = join(base, ...rest);
  if (!resolve(file).startsWith(resolve(root))) return null;
  if (isDir(file)) file = join(file, 'index.html');
  return isFile(file) ? { file } : null;
}

/** parcel watch of the shell and of every cloned app, with the public URL the server mounts it at. */
function startWatchers(root: string): void {
  const children: Array<ReturnType<typeof Bun.spawn>> = [];
  const watch = (cwd: string, publicUrl: string) => {
    const script = `[ -d node_modules ] || bun install --frozen-lockfile; exec bunx parcel watch --no-cache --no-source-maps --no-hmr --dist-dir ./dist --public-url ${publicUrl}`;
    children.push(Bun.spawn(['bash', '-c', script], { cwd, stdout: 'inherit', stderr: 'inherit' }));
  };
  // Ctrl+C or pm2 stop: stop the watchers too, so no parcel keeps running in the background
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.on(signal, () => {
      for (const child of children) child.kill();
      process.exit(0);
    });
  }
  watch(root, '/');
  for (const repo of APP_REPOS) {
    if (existsSync(join(root, repo, 'package.json'))) watch(join(root, repo), `/${repo}/`);
    else console.log(`${repo} is not cloned: served from ${GITHUB_PAGES_ORIGIN}${repo}/ (./scripts/install.sh ${repo})`);
  }
}

if (import.meta.main) {
  const root = resolve(import.meta.dir, '..');
  if (process.argv.includes('--watch')) startWatchers(root);
  const server = Bun.serve({
    port: Number(process.env.PORT || 1234),
    fetch(request) {
      const url = new URL(request.url);
      const found = resolveRequest(root, url.pathname, url.search);
      if (found && 'redirect' in found) return Response.redirect(found.redirect, 302);
      if (found) return new Response(Bun.file(found.file), { headers: { 'Cache-Control': 'no-cache' } });
      return new Response('Not found', { status: 404 });
    },
  });
  console.log(`Investments: ${server.url}`);
}

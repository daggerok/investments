# Investments

All investment tools in one app, one tab per tool:

- **ETFs** - the [ETFs hub](https://github.com/daggerok/ETFs): every ETF of the 29 brand repositories in one sortable table, cross-brand Watchlist with aggregated holdings, per-fund Overview, Holdings, History and Distributions tabs
- **Stocks** - the [Stocks](https://github.com/daggerok/Stocks) catalog: Nasdaq, NYSE and Cboe stocks with fundamentals, dividends, valuation multiples, momentum and total returns

Each tab is the real, unchanged application of its own repository shown in a frame, so it keeps all of its functionality, URL parameters and saved state. Opened tabs stay loaded, so switching between them loses nothing. The theme is shared: toggling it inside one app switches the others. The shown tab is in the URL (`#etfs`, `#stocks`) and remembered in the browser. `Open in a new tab` opens the shown app on its own

The application is published at <https://daggerok.github.io/investments/>. There the tabs show the apps' own GitHub Pages sites, so the shell is the only thing this repository deploys (`.github/workflows/github-pages.yml`)

## Using Bun

```bash
git clone https://github.com/daggerok/investments && cd investments
./scripts/install.sh --depth 1
bun run serve
```

`./scripts/install.sh` clones the ETFs hub, Stocks and the 29 ETF brand repositories into subfolders of this one (they are ignored by `.gitignore`), so the whole layout is:

```
investments/          this repo: the shell (src/) and the scripts (scripts/)
  ETFs/               the ETFs hub repo
  Stocks/             the Stocks repo (its data: Stocks/api/stocks)
  AAM/ ... iShares/   the 29 ETF brand repos (their data: <Brand>/api/<slug>)
```

`bun run serve` builds the shell (`bun run build`), builds ETFs and Stocks inside their own folders with their own `build-github-pages` script (`bun run build-apps`, packages are installed first when missing) and starts `scripts/serve.ts` on <http://localhost:1234> (`PORT=4000 bun run serve` to change it). `bun run dev` serves the same way and rebuilds the shell, ETFs and Stocks with `parcel watch` on every change: reload the page to see it. Ctrl+C stops the watchers too

### Data: one copy, used everywhere

The data lives only in the repository it belongs to and is never copied. Update a brand once (here with `./scripts/update-data.sh iShares`, in the ETFs hub, in the brand repository itself or by its scheduled workflow) and the same `api/` is what the brand app, the ETFs hub and this app read. Same for Stocks

The local server maps every app to the cloned folders:

| Request | Served from |
| --- | --- |
| `/` | `dist/` (the shell) |
| `/ETFs/<Brand>/api/**` | `<Brand>/api/**`: the hub reads `./<Brand>/api/<slug>/` next to its page, exactly as in the ETFs repo layout |
| `/ETFs/**` | `ETFs/dist/**` |
| `/Stocks/api/**` | `Stocks/api/**`, always the current feed |
| `/Stocks/**` | `Stocks/dist/**` |

A brand or Stocks feed that is not cloned is a 404, which the apps already answer by reading that feed from GitHub Pages (the hub marks such a brand `remote`). An app that is not cloned or not built is redirected to its GitHub Pages site. `?api=remote` (`http://localhost:1234/?api=remote`) makes both apps read GitHub Pages and `?api=local` keeps them strictly local: the parameter is passed on to the apps

### Scripts

All scripts resolve this folder from their own location, so they work from any working directory. Every cloned repository stays an independent git repository, so you can develop, commit and open pull requests in any of them separately

- `./scripts/install.sh` checks that git is installed, installs bun with the official script when missing, runs `bun i -E` here and clones the repositories. No arguments clones all 31; repositories can be listed separated by spaces and/or commas, case-insensitive (`./scripts/install.sh Stocks VanEck,Tema`). `-d 1` / `--depth 1` is the fastest and smallest way to just run the app, `-s` / `--ssh` clones over SSH, `-p N` / `--parallel N` sets the parallel clones. Already cloned repositories are skipped
- `./scripts/update.sh` fetches (with prune and tags) and fast-forwards `main` (or `master`) of every cloned repository, so you get the data others pushed. It switches every repository to that branch first, so commit or stash work in progress before running it. Same arguments (`./scripts/update.sh ETFs Stocks`, `-p N`)
- `./scripts/update-data.sh` refreshes the data of Stocks and the brands one after another with each repository's own updater, then commits and pushes it the way its `update-data.yml` workflow does: pull `main` fast-forward, `bun install --frozen-lockfile`, `./scripts/update-data.ts`, `git add api/<feed>`, commit, push (when `main` moved meanwhile it rebases the data commit and retries). The feed folder and the commit message are read from the repository's workflow; the ETFs hub has no data and is not listed. A repository that is not on `main` or has uncommitted changes is skipped and reported, never touched. `--no-push` commits without pushing; update controls are environment variables passed to every updater (`REQUEST_SLEEP=1 ./scripts/update-data.sh VanEck`, `TICKERS=AAPL ./scripts/update-data.sh Stocks`). A summary lists every repository at the end and the exit code is non-zero if any failed. Useful where a provider blocks GitHub's runners, since the data comes from your own connection
- `./scripts/clean.sh` removes cloned repositories again (all, or the listed ones). A repository with uncommitted changes, ignored files other than `node_modules/`, `dist/`, `.parcel-cache/` and `.idea/`, unpushed commits, a detached-HEAD commit or stash entries is never removed, and neither is one on which git itself fails: it is kept with a message, so no work is lost
- `./scripts/build-apps.sh [ETFs] [Stocks]` builds the apps for the local server (called by `bun run serve`)

Every script prints its usage with `-h` / `--help`

## TypeScript and verification

The shell is built by Parcel: `src/index.html` carries the markup, `src/index.css` the Tailwind CSS v4 styles and `src/main.ts` the tab logic. There is no `tsconfig.json`; Bun runs TypeScript out of the box

```bash
bun test                       # scripts/investments.test.ts: shell markup, script repo lists, server routing
bun run build-github-pages     # the published shell
```

Each app is verified in its own repository

## License

[MIT](./LICENSE)

Investments is an independent, unofficial tool; it is not affiliated with, endorsed by, or sponsored by any ETF issuer or listed company. It only combines the public static feeds of the daggerok repositories, which are generated from the issuers' public pages and downloads, public SEC EDGAR filings and Yahoo Finance. Fund names, tickers and brand names are trademarks of their respective owners. Nothing here is investment advice

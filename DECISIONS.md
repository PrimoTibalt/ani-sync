# Decisions

Newest at the bottom. Each entry: what was decided, and why.

## 2026-10-11: Initial design

1. **Implicit OAuth grant, no client secret.** Login opens
   `anilist.co/api/v2/oauth/authorize?client_id=53505&response_type=token`; the
   user pastes the token (or the redirect URL containing `access_token=`).
   A bash script can't keep a secret, and the implicit grant doesn't need one,
   so the secret is not stored anywhere in the project. The client id can be
   overridden with `ANI_SYNC_CLIENT_ID`.
   *Note:* this works best if the AniList API client's redirect URL is
   `https://anilist.co/api/v2/oauth/pin` (AniList then shows the token on the page).
   With any other redirect URL the user has to copy the token from the address bar.

2. **Pure-bash TUI instead of fzf.** fzf's always-on query field conflicts with
   vim keys (typing `j` filters instead of moving). The custom list widget gives
   real vim behaviour (j/k, counts, gg/G, Ctrl-d/u/f/b, `/` filter, h/l, Esc)
   with no extra dependency.

3. **Drive ani-cli, don't re-implement scraping.** Playback is
   `ani-cli --no-detach --exit-after-play -e EP [--dub] QUERY`. Providers change
   often, and ani-cli updates (`ani-cli -U`) keep working for us.

4. **Answer ani-cli's anime menu through `ANI_CLI_MENU`.** ani-cli calls a custom
   menu program with the results on stdin; `libexec/ani-sync-menu` picks the
   remembered match, else a unique exact (normalised) title match, else shows our
   own picker and remembers the answer. The user can force the picker again
   with `p` (Watch list, or after a failed play).

5. **Search query = English title, then romaji**, with punctuation removed (the
   provider search chokes on `:` and `’`). The query that worked is remembered.

6. **Mark-as-watched is confirmed after playback, not automatic.** mpv exits 0
   whether the episode finished or the user quit after a minute, so the app asks:
   `y` mark + next, `m` mark + back, `r` replay, `n` don't mark.

7. **Status transitions when marking:** progress = episode; status becomes
   COMPLETED at the last episode (REPEATING → COMPLETED with `repeat+1`),
   stays REPEATING while rewatching, otherwise CURRENT (so PLANNING and
   not-on-list shows move to Watching).

8. **Watch list = CURRENT + REPEATING + PLANNING entries with unwatched
   released episodes.** "Search → add" puts shows in PLANNING, so they must show
   up in Watch. PAUSED/DROPPED are left out on purpose. Shows with an unknown
   number of released episodes (airing, no schedule) are kept.

9. **Ordering by the time of the latest released episode**, newest first:
   exact `airingAt` of the newest aired episode (last 30 days, via
   `Page.airingSchedules`), else next episode time − 7 days, else end date
   (finished shows), else start date. The per-episode `AiringSchedule` lookup was
   rejected because one 404 inside a batched GraphQL query nulls all results.

10. **Sub/dub is asked every time** you start watching a show (as requested),
    with the cursor on the last choice for that show.

11. **ani-cli history is redirected** to `~/.local/state/ani-sync/ani-cli` so
    our plays don't mix with the user's own ani-cli history.

12. **Search hides adult entries** (`isAdult: false`).

## 2026-10-11: Try every AniList name when searching the source

Hen Zemi couldn't be found: AniList's titles ("Hen Zemi (TV)", no English
title) return unrelated results on ani-cli's source, which lists it as
"Abnormal Physiology Seminar", one of AniList's *synonyms*. Changes
(replaces the query part of decision 5):

- Queries tried in order: remembered query → English → romaji → Latin-script
  synonyms (max 6, deduplicated, punctuation stripped).
- While more queries remain, the menu helper runs in *strict* mode
  (`ANI_SYNC_STRICT=1`): it only answers when a result's title matches an
  AniList name (ignoring case, punctuation and `(TV)`-style parts); otherwise it
  creates `$ANI_SYNC_TMP/nomatch` and fails so the next name is tried. An
  unrelated result list no longer stops the search.
- If no name matches, ani-cli is run once more with the first query that had
  results and the picker is shown.
- New `c` option on the "couldn't play" screen: search the source with a title
  you type.
- *Correction:* the Hen Zemi "fix" was wrong. The source does **not** have Hen
  Zemi; "Abnormal Physiology Seminar" returns only *Medaka Box Abnormal*, which
  ani-cli played without asking (see next entry).

## 2026-10-11: Check every pick at the player, not only in the menu

Bug: ani-cli picks a lone search result without calling `ANI_CLI_MENU`, so the
title check never ran. A custom search played the wrong show, and `p` (re-pick)
did nothing for one-result searches.

- ani-sync now sets `ANI_CLI_PLAYER=libexec/ani-sync-mpv`, which runs the real
  mpv (`ANI_SYNC_REAL_PLAYER`). Every play goes through it. It reads
  `--force-media-title` ("<show> Episode <n>") and only plays if the show is
  the remembered pick or matches an AniList name. Otherwise, in strict mode it
  fails with `nomatch` (try the next name), or it asks "Is that <anime>?" (y/n).
  The file name must contain `mpv` so ani-cli passes mpv-style arguments.
- Only wrapped when the player is mpv (the default on Linux). With
  `ANI_CLI_PLAYER=vlc`/flatpak, single results stay unchecked.
- `p` = "ask me next time" (`!pick`): the picker for several results, the y/n
  check for one. On the failure screen `p` retries right away.
- A custom search (`c`) is used for one try only, always asks for
  confirmation, and is saved as the anime's query only once something plays.
  It used to be saved immediately, so a typo stuck around.
- A remembered query that stops finding the anime is forgotten.
- Rejecting a result (picker `q` or `n`) stops the search (`rejected` marker)
  with a clear message, and nothing is marked as watched.

## 2026-10-11: Packaging for the AUR

- **License GPL-3.0-or-later**, the same as ani-cli.
- **Install layout:** `/usr/lib/ani-sync/{ani-sync,lib,libexec}` plus a
  relative symlink `/usr/bin/ani-sync`. The script finds its files through
  `readlink -f`, so the symlink works without any path patching. `make install`
  (PREFIX/DESTDIR) does the work, and the PKGBUILD only calls it.
- **Release package (`ani-sync`), not `-git`:** it builds from GitHub tag
  tarballs (`v$pkgver`). `packaging/aur/` holds the PKGBUILD; the AUR repo
  itself is a separate git repo that only contains `PKGBUILD` + `.SRCINFO`.
- **Depends on `ani-cli` (itself an AUR package), plus `mpv`:** the
  pick-check wrapper needs mpv. `xdg-utils` is optional (browser for login).
- The license file isn't installed: Arch ships the GPL-3.0 text in `licenses`.

## 2026-10-11: Not on the AUR yet

AUR registration is closed to new users, so the package isn't published. The
PKGBUILD stays in `packaging/aur/` for when it reopens (or for local `makepkg -si`).
Local install: symlink `~/.local/bin/ani-sync` → the repo's `ani-sync`.

## 2026-10-19: Omarchy theme colours

- **Source:** `~/.local/state/omarchy/current/theme/colors.toml`, the theme
  Omarchy has applied (its own templates are generated from it). Parsed with a
  plain `read` loop, no TOML library. Only `#rrggbb` values are taken.
- **Mapping:** accent → `C_ACCENT`; title bar = accent background with the
  theme's background as text; selected row = `selection` background with bold
  accent text (like Omarchy's other apps, instead of reverse video);
  yellow → `C_WARN`, green → `C_OK`. `C_DIM` stays faint (SGR 2): the themes'
  `muted`/`light_foreground` aren't consistent enough between themes to use.
- **Fallback:** without the file, without `COLORTERM=truecolor|24bit`, or with
  `ANI_SYNC_THEME=default`, the plain ANSI colours stay. Those already follow
  the terminal's palette, so non-Omarchy systems look as before.
- Read once at startup; no live reload on `omarchy theme set` (not worth a
  file watch for a short-lived TUI).

## 2026-10-19: Dropping / removing an anime

- `d` on Watch (and "Drop / remove" in search actions) asks first, then offers
  both: **Dropped** status (AniList's own way to stop a show; progress and
  history stay, and the Watch query only fetches CURRENT/REPEATING/PLANNING so
  it disappears) or **delete** the list entry (for things added by mistake).
- `DeleteMediaListEntry` needs the list entry id, not the media id. Rows don't
  carry it, so `al_delete` looks it up with `MediaList(userId, mediaId)`
  instead of adding a column to every TSV row.
- Per-anime prefs (`prefs.tsv`) are kept: harmless, and useful if the show is
  added again.

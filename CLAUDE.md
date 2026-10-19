# ani-sync

Bash TUI that joins AniList (progress tracking) with ani-cli (playback).
AniList is the single source of truth for what has been watched; ani-cli's own
history is not used.

## Layout

- `ani-sync`: entry point: arg parsing, login, screens (Home, Watch, Search),
  watch flow (sub/dub → play → mark watched).
- `lib/tui.sh`: vim-style TUI toolkit (`tui_list`, `tui_prompt`, `tui_input`,
  `tui_loading`, `tui_help`). Draws only to fd 3 (`/dev/tty`). Colours are the
  `C_*` globals: plain ANSI by default, replaced by the Omarchy theme's
  truecolor values when `~/.local/state/omarchy/current/theme/colors.toml`
  exists (`_tui_omarchy_theme`; `ANI_SYNC_THEME=default` opts out). Never
  hard-code escapes elsewhere: use `C_*`.
- `lib/anilist.sh`: GraphQL client (`al_query`) + queries (`al_viewer`,
  `al_watch_list`, `al_search`, `al_save`, `al_delete`). `AL_JQ_ROW` turns media into the TSV
  row format every screen uses.
- `lib/player.sh`: `play_episode` runs `ani-cli --no-detach --exit-after-play`.
- `lib/state.sh`: token file + per-anime prefs (`prefs.tsv`).
- `libexec/ani-sync-menu`: `ANI_CLI_MENU` replacement that answers ani-cli's
  "Select anime" prompt (remembered pick → exact title match → picker; in
  strict mode it fails instead of guessing so `play_episode` can try the next
  AniList name: English, romaji, synonyms). Not called when a search has one
  result, which is why the player wrapper exists.
- `libexec/ani-sync-mpv`: `ANI_CLI_PLAYER` wrapper around mpv; the final check
  that ani-cli's pick is the right show (asks y/n when unsure).
- `lib/match.sh`: title normalisation/matching shared by both helpers.

## Conventions

- Bash 5, deps: ani-cli, curl, jq, awk, stty (+ xdg-open optional). No other deps.
- 4-space indent, `local` everything, globals UPPER_CASE (`R_*` = parsed row,
  `TUI_*` = TUI in/out, `AL_*` = AniList).
- TSV rows must never contain empty fields (`read` with IFS=tab collapses
  them): use `-` / `-1` placeholders. The last column (synonyms) is joined
  with `\x1f`.
- Never put the token on a command line; curl reads it from `$ANI_SYNC_TMP/auth.hdr`.
- Every key binding must be vim-style; add new screen keys to the screen's hint
  line, and global ones to `tui_help`.
- Record every non-obvious design choice in `DECISIONS.md` (newest at the bottom).

## Releasing

1. Bump `VERSION` in `ani-sync` and `pkgver` in `packaging/aur/PKGBUILD` (reset `pkgrel=1`).
2. Commit, `git tag vX.Y.Z`, `git push --follow-tags`.
3. In `packaging/aur/`: `updpkgsums && makepkg -f && makepkg --printsrcinfo > .SRCINFO`.
4. Copy `PKGBUILD` + `.SRCINFO` into the AUR clone (`ssh://aur@aur.archlinux.org/ani-sync.git`), commit, push.

`make check` = `bash -n` on every script; `make install PREFIX=… DESTDIR=…`.

## Files at runtime

- `~/.config/ani-sync/token`: AniList access token (mode 600, valid ~1 year)
- `~/.local/state/ani-sync/prefs.tsv`: `id  mode  query  provider-title`
  (`!pick` in the last column forces the picker next time)
- `~/.local/state/ani-sync/ani-cli/`: ani-cli's history, kept apart from the user's
- `~/.local/state/omarchy/current/theme/colors.toml`: read-only, Omarchy theme colours

## Testing

No test suite yet. Manual testing used tmux to drive the TUI:
`tmux new-session -d -s t -x 110 -y 30 'XDG_CONFIG_HOME=/tmp/x XDG_STATE_HOME=/tmp/x ./ani-sync'`
then `tmux send-keys` / `tmux capture-pane -p`. To test playback without
video, point `ANI_CLI_PLAYER` at a fake script whose name contains `mpv` and
which prints its `--force-media-title`. Always check *which show* played: a
stream link alone proves nothing. (`ANI_CLI_PLAYER=debug` bypasses the wrapper.) Public AniList lists (e.g.
user id 5) can be read without a token to test `al_watch_list`.
Check colours with `tmux capture-pane -p -e | cat -v` (with and without
`ANI_SYNC_THEME=default`).
`bash -n` every file after edits (shellcheck isn't installed here).

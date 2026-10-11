# ani-sync

A vim-style terminal UI that plays anime with [ani-cli](https://github.com/pystardust/ani-cli)
and keeps your progress on [AniList](https://anilist.co).

AniList is the only record of what you've watched (ani-cli's own history isn't used):

- **Watch** lists everything you're watching, rewatching or planning that has
  episodes out you haven't seen. The show with the newest episode is at the top.
- Pick a show, choose **subtitles or dub**, and the next episode plays in mpv.
- When the player closes, press `y` to mark the episode watched on AniList and
  play the next one, `m` to mark it and go back, `r` to replay, or `n` to skip.
- **Search** AniList and add shows to your Planning list, or start watching them.

## Install

Arch Linux (AUR):

```sh
yay -S ani-sync     # or paru, or: git clone https://aur.archlinux.org/ani-sync.git && cd ani-sync && makepkg -si
```

Anywhere else (needs bash 5, ani-cli, mpv, curl, jq):

```sh
sudo make install            # PREFIX=/usr/local by default
sudo make uninstall
```

## First run

`ani-sync` asks you to log in once: press `o` to open AniList in your browser,
approve the app, copy the token AniList shows you, then press `p` and paste it.
The token is saved in `~/.config/ani-sync/token` (readable only by you, valid
about a year). `ani-sync --logout` forgets it.

## Keys

| Key | Action |
| --- | --- |
| `j` / `k` (counts work: `5j`) | down / up |
| `gg` / `G` | first / last |
| `Ctrl-d` / `Ctrl-u`, `Ctrl-f` / `Ctrl-b` | half / full page |
| `l` / Enter | open, select |
| `h` / `q` / Esc | back (`q` on Home quits) |
| `/` | filter the list |
| `?` | help |

Each screen lists its own extra keys at the bottom (e.g. `r` refresh, `a` add to Planning).

## Finding the right show

ani-cli's source often names shows differently from AniList. ani-sync tries
the English title, the romaji title and AniList's other names in turn, and
only plays a result whose title matches one of them. When it isn't sure, it
asks before playing. If playback fails you can:

- `c`: search with a title you type
- `p`: choose the show yourself
- `s`: switch between sub and dub

Some shows simply aren't on ani-cli's source.

## Configuration

- `ANI_CLI_*` variables (quality, player, …) are passed through to ani-cli.
  The check that the right show is playing only works with mpv (the default).
- `ANI_SYNC_CLIENT_ID`: use your own AniList API client. Its redirect URL must be
  `https://anilist.co/api/v2/oauth/pin`.

## License

GPL-3.0-or-later

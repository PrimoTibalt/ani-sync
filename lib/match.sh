# shellcheck shell=bash
# Does a title from ani-cli's source belong to the AniList entry being played?
# ANI_SYNC_TITLES holds the entry's names (English, romaji, synonyms), one per line.

# lowercase, no "(TV)"-style parts, no punctuation/spaces
title_norm() {
    local s=${1,,}
    s=$(sed 's/([^)]*)//g' <<<"$s")
    printf '%s' "${s//[^[:alnum:]]/}"
}

# title_matches TITLE: true when TITLE equals one of the AniList names
title_matches() {
    local want t
    want=$(title_norm "$1")
    [ -n "$want" ] || return 1
    while IFS= read -r t; do
        [ -n "$t" ] && [ "$t" != "-" ] || continue
        [ "$(title_norm "$t")" = "$want" ] && return 0
    done <<<"${ANI_SYNC_TITLES:-}"
    return 1
}

# display name of the AniList entry (first known name)
title_wanted() {
    local t
    while IFS= read -r t; do
        [ -n "$t" ] && [ "$t" != "-" ] && { printf '%s' "$t"; return; }
    done <<<"${ANI_SYNC_TITLES:-}"
}

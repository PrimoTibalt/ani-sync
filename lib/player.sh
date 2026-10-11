# shellcheck shell=bash
# Playback through ani-cli. ani-cli does the scraping and runs mpv; we pick
# the episode/mode, answer its "Select anime" menu via ANI_CLI_MENU
# (libexec/ani-sync-menu) and check the final pick via ANI_CLI_PLAYER
# (libexec/ani-sync-mpv, ani-cli skips the menu for a lone result).

# search_terms TITLE -> a provider-friendly search query
search_terms() {
    local s=${1//[\'’]/}
    [ "$s" = "-" ] && return
    s=${s//[^[:alnum:]]/ }
    read -ra s <<<"$s"
    printf '%s' "${s[*]}"
}

# _run_ani_cli QUERY STRICT: one ani-cli run. STRICT=1 makes the helpers
# refuse to guess (they create $ANI_SYNC_TMP/nomatch instead) so the next
# query can be tried. Returns ani-cli's exit code.
_run_ani_cli() {
    local rc
    rm -f "$ANI_SYNC_TMP/nomatch" "$ANI_SYNC_TMP/rejected"
    printf '\n\e[1;36m▶ %s — episode %s (%s)\e[0m  \e[2msearching ani-cli for "%s"\e[0m\n' \
        "$PLAY_NAME" "$PLAY_EP" "$PLAY_MODE" "$1"
    # shellcheck disable=SC2086 # ani-cli wants the query as separate words
    ANI_CLI_MENU="$ANI_SYNC_ROOT/libexec/ani-sync-menu" \
        ANI_CLI_PLAYER=$PLAY_PLAYER ANI_SYNC_REAL_PLAYER=$PLAY_REAL_PLAYER \
        ANI_CLI_HIST_DIR="$STATE_DIR/ani-cli" \
        ANI_SYNC_MEDIA_ID=$PLAY_ID ANI_SYNC_TITLES=$PLAY_TITLES ANI_SYNC_STRICT=$2 \
        ani-cli "${PLAY_FLAGS[@]}" $1 2> >(tee "$ANI_SYNC_TMP/ani-cli.err" >&2)
    rc=$?
    wait $! 2>/dev/null # let tee finish writing
    if [ -f "$ANI_SYNC_TMP/nomatch" ]; then
        printf '\e[2m  no result matches this anime, trying its next name…\e[0m\n'
    fi
    return $rc
}

# play_episode MEDIA_ID EPISODE MODE(sub|dub) ENGLISH ROMAJI SYNONYMS [QUERY]
# SYNONYMS are separated by \x1f. Without QUERY every name of the anime is
# tried: remembered query, English, romaji, Latin-script synonyms. A result
# is only accepted when its title matches one of those names; if none does,
# the first query that had results is run again and the user decides.
# With QUERY (a custom search) only that query is run and the user always
# confirms the pick. Runs ani-cli in the foreground with the TUI suspended.
# Returns ani-cli's exit code (0 = played); PLAY_ERR explains failures.
play_episode() {
    local q t dup rc=1 fallback="" last i remembered notfound=1
    local -a queries=() syns=() uniq=()
    PLAY_ID=$1 PLAY_EP=$2 PLAY_MODE=$3
    PLAY_NAME=$4
    [ "$PLAY_NAME" = - ] && PLAY_NAME=$5
    PLAY_FLAGS=(--no-detach --exit-after-play -e "$PLAY_EP")
    [ "$PLAY_MODE" = dub ] && PLAY_FLAGS+=(--dub)
    IFS=$'\x1f' read -ra syns <<<"${6:-}"
    [ "${syns[0]:-}" = - ] && syns=()
    PLAY_TITLES=$(printf '%s\n' "$4" "$5" "${syns[@]}")

    # the pick can only be checked when ani-cli runs mpv through our wrapper
    PLAY_PLAYER=${ANI_CLI_PLAYER:-} PLAY_REAL_PLAYER=""
    t=${ANI_CLI_PLAYER:-mpv}
    if [[ $t == *mpv* && $t != *flatpak* ]] && command -v "$t" >/dev/null; then
        PLAY_PLAYER="$ANI_SYNC_ROOT/libexec/ani-sync-mpv" PLAY_REAL_PLAYER=$t
    fi

    remembered=$(state_get "$PLAY_ID" $PREF_QUERY)
    if [ -n "${7:-}" ]; then
        queries=("$7")
        state_set "$PLAY_ID" $PREF_PICK "!pick"
    else
        queries=("$remembered" "$(search_terms "$4")" "$(search_terms "$5")")
        for t in "${syns[@]}"; do
            t=$(search_terms "$t")
            [[ $t == *[![:ascii:]]* ]] || queries+=("$t")
        done
    fi
    for t in "${queries[@]}"; do
        [ -n "$t" ] || continue
        dup=0
        for q in "${uniq[@]}"; do [ "$q" = "$t" ] && dup=1; done
        (( dup )) || uniq+=("$t")
    done
    queries=("${uniq[@]:0:6}")
    PLAY_ERR=""
    if (( ${#queries[@]} == 0 )); then
        PLAY_ERR="no title to search for"
        return 1
    fi

    tui_suspend
    trap ':' INT # Ctrl-C stops ani-cli/mpv, not us
    last=$(( ${#queries[@]} - 1 ))
    for i in "${!queries[@]}"; do
        q=${queries[i]}
        _run_ani_cli "$q" $(( i < last ))
        rc=$?
        (( rc == 0 )) && break
        [ -f "$ANI_SYNC_TMP/rejected" ] && break
        if [ -f "$ANI_SYNC_TMP/nomatch" ]; then
            [ -z "$fallback" ] && fallback=$q
        elif ! grep -q "No results found" "$ANI_SYNC_TMP/ani-cli.err"; then
            notfound=0
            break # a real error (no sources, episode missing, Ctrl-C...)
        fi
    done
    # nothing matched by name: let the user judge the first result list
    if (( rc != 0 )) && [ ! -f "$ANI_SYNC_TMP/rejected" ] && (( notfound )) &&
        [ -n "$fallback" ] && [ "$fallback" != "${queries[last]}" ]; then
        _run_ani_cli "$fallback" 0
        rc=$?
        q=$fallback
    fi
    trap 'exit 130' INT

    if (( rc == 0 )); then
        state_set "$PLAY_ID" $PREF_QUERY "$q"
    elif [ -f "$ANI_SYNC_TMP/rejected" ]; then
        PLAY_ERR="Cancelled: ani-cli's results for \"$q\" aren't this anime."
    elif (( notfound )); then
        PLAY_ERR="ani-cli's source doesn't seem to have it (searched: $(printf '"%s", ' "${queries[@]}" | sed 's/, $//'))."
    else
        PLAY_ERR=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$ANI_SYNC_TMP/ani-cli.err" | grep -v '^[[:space:]]*$' | tail -n 1)
    fi
    # a remembered query that no longer finds the anime is useless
    if (( rc != 0 )) && [ -z "${7:-}" ] && [ -n "$remembered" ] && (( notfound )); then
        state_set "$PLAY_ID" $PREF_QUERY ""
    fi
    tui_resume
    return $rc
}

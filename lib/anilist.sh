# shellcheck shell=bash
# AniList GraphQL API (https://docs.anilist.co).
# Auth uses the implicit grant: the user approves the app in a browser and
# pastes back the access token, so no client secret is needed (or stored).

AL_API=https://graphql.anilist.co
AL_CLIENT_ID=${ANI_SYNC_CLIENT_ID:-53505}
AL_AUTH_URL="https://anilist.co/api/v2/oauth/authorize?client_id=${AL_CLIENT_ID}&response_type=token"

AL_MEDIA_FIELDS='id title { romaji english } synonyms status format episodes seasonYear
    nextAiringEpisode { episode airingAt }
    startDate { year month day } endDate { year month day }'

# Turns media (+ optional list entry) into one TSV row; every field is
# non-empty ("-" / -1 placeholders) because `read` collapses empty TSV fields.
# Columns: id title progress available total media_status list_status
#          latest_release_ts repeat english romaji format year synonyms
# synonyms are joined with \x1f (unit separator).
# available = episodes out now, -1 if unknown.
AL_JQ_ROW='
def pad: tostring | if length < 2 then "0" + . else . end;
def ts: if .year then "\(.year)-\(.month // 1 | pad)-\(.day // 1 | pad)" | strptime("%Y-%m-%d") | mktime else null end;
def clean: gsub("[\t\n\r]"; " ") | if . == "" then "-" else . end;
def avail:
    if .nextAiringEpisode then .nextAiringEpisode.episode - 1
    elif .status == "NOT_YET_RELEASED" then 0
    elif .status == "RELEASING" or .status == "HIATUS" then -1
    else .episodes // -1 end;
def latest($sched):
    if $sched[.id | tostring] then $sched[.id | tostring]
    elif .nextAiringEpisode and .nextAiringEpisode.episode > 1 then .nextAiringEpisode.airingAt - 604800
    elif .status == "FINISHED" then (.endDate | ts) // (.startDate | ts) // 0
    else (.startDate | ts) // 0 end;
def row($lang; $sched; $e):
    [ .id,
      ((if $lang | test("ENGLISH") then .title.english // .title.romaji else .title.romaji // .title.english end) // "?" | clean),
      ($e.progress // 0), avail, (.episodes // -1), .status, ($e.status // "-"),
      latest($sched), ($e.repeat // 0),
      (.title.english // "" | clean), (.title.romaji // "" | clean),
      (.format // "-" | clean), (.seasonYear // .startDate.year // "-"),
      ((.synonyms // []) | map(clean) | join("\u001f") | clean)
    ] | @tsv;
'

al_err() { printf '%s' "$1" >"$ANI_SYNC_TMP/al.err"; }
al_last_error() { cat "$ANI_SYNC_TMP/al.err" 2>/dev/null; }

al_set_token() {
    AL_TOKEN=$1
    (umask 077 && printf 'Authorization: Bearer %s\n' "$AL_TOKEN" >"$ANI_SYNC_TMP/auth.hdr")
}

# al_query QUERY [VARIABLES_JSON] -> prints the .data object.
# Returns 1 on errors (see al_last_error), 2 when the token is rejected.
al_query() {
    local vars=${2:-'{}'} resp code body msg tries=0 wait_s
    local -a auth=()
    [ -n "${AL_TOKEN:-}" ] && auth=(-H "@$ANI_SYNC_TMP/auth.hdr") # keeps the token out of `ps`
    body=$(jq -nc --arg q "$1" --argjson v "$vars" '{query: $q, variables: $v}') || {
        al_err "internal error: bad query variables"
        return 1
    }
    while :; do
        resp=$(curl -sS --max-time 20 -D "$ANI_SYNC_TMP/al.hdr" -w '\n%{http_code}' \
            -H 'Content-Type: application/json' -H 'Accept: application/json' \
            "${auth[@]}" --data "$body" "$AL_API" 2>&1)
        code=${resp##*$'\n'} resp=${resp%$'\n'*}
        if [[ $code != [0-9][0-9][0-9] || $code == 000 ]]; then
            al_err "network error: ${resp:-no response}"
            return 1
        fi
        if [ "$code" = 429 ] && (( tries++ < 2 )); then
            wait_s=$(sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9]*\).*/\1/p' "$ANI_SYNC_TMP/al.hdr")
            sleep "${wait_s:-5}"
            continue
        fi
        break
    done
    msg=$(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp" 2>/dev/null)
    if [ "$code" = 401 ] || [[ $msg == *"Invalid token"* || $msg == *Unauthorized* ]]; then
        al_err "AniList rejected the login token"
        return 2
    fi
    if [ -n "$msg" ] || [ "$code" != 200 ]; then
        al_err "AniList error (HTTP $code): ${msg:-unexpected response}"
        return 1
    fi
    jq -c '.data' <<<"$resp"
}

# -> "id<TAB>name<TAB>titleLanguage"
al_viewer() {
    local data
    data=$(al_query '{ Viewer { id name options { titleLanguage } } }') || return
    jq -r '.Viewer | [.id, .name, (.options.titleLanguage // "ROMAJI")] | @tsv' <<<"$data"
}

# al_watch_list USER_ID TITLE_LANG -> TSV rows (see AL_JQ_ROW) of anime with
# episodes out that the user hasn't watched, newest release first.
al_watch_list() {
    local data ids sched='{}' page=1 since part
    data=$(al_query "query (\$u: Int) {
        MediaListCollection(userId: \$u, type: ANIME, status_in: [CURRENT, REPEATING, PLANNING]) {
            lists { entries { status progress repeat media { $AL_MEDIA_FIELDS } } }
        } }" "{\"u\": $1}") || return
    data=$(jq -c '[.MediaListCollection.lists[].entries[]] | unique_by(.media.id)' <<<"$data")

    # exact time of the latest aired episode for airing shows (last 30 days)
    ids=$(jq -c '[.[].media | select(.status == "RELEASING") | .id]' <<<"$data")
    if [ "$ids" != "[]" ]; then
        since=$(( $(date +%s) - 30 * 86400 ))
        while (( page <= 3 )); do
            part=$(al_query 'query ($ids: [Int], $since: Int, $p: Int) {
                Page(page: $p, perPage: 50) {
                    pageInfo { hasNextPage }
                    airingSchedules(mediaId_in: $ids, notYetAired: false, airingAt_greater: $since, sort: TIME_DESC) { mediaId airingAt }
                } }' "{\"ids\": $ids, \"since\": $since, \"p\": $page}") || break
            sched=$(jq -c --argjson s "$sched" \
                'reduce .Page.airingSchedules[] as $a ($s; .[$a.mediaId | tostring] |= ([., $a.airingAt] | max))' <<<"$part")
            [ "$(jq -r '.Page.pageInfo.hasNextPage' <<<"$part")" = true ] || break
            (( page++ ))
        done
    fi

    jq -r --arg lang "$2" --argjson sched "$sched" "$AL_JQ_ROW"'
        map(. as $e | .media | {e: $e, m: ., a: avail, l: latest($sched)})
        | map(select(.a == -1 or .a > (.e.progress // 0)))
        | sort_by(-.l)[]
        | .e as $e | .m | row($lang; $sched; $e)' <<<"$data"
}

# al_search QUERY TITLE_LANG -> TSV rows (see AL_JQ_ROW)
al_search() {
    local data
    data=$(al_query "query (\$s: String) {
        Page(perPage: 30) {
            media(search: \$s, type: ANIME, sort: SEARCH_MATCH, isAdult: false) {
                $AL_MEDIA_FIELDS mediaListEntry { status progress repeat }
            } } }" "$(jq -nc --arg s "$1" '{s: $s}')") || return
    jq -r --arg lang "$2" "$AL_JQ_ROW"'.Page.media[] | row($lang; {}; .mediaListEntry)' <<<"$data"
}

# al_save MEDIA_ID PROGRESS STATUS [REPEAT]
al_save() {
    al_query 'mutation ($id: Int, $p: Int, $s: MediaListStatus, $r: Int) {
        SaveMediaListEntry(mediaId: $id, progress: $p, status: $s, repeat: $r) { id progress status } }' \
        "$(jq -nc --argjson id "$1" --argjson p "$2" --arg s "$3" --arg r "${4:-}" \
            '{id: $id, p: $p, s: $s} + (if $r == "" then {} else {r: ($r | tonumber)} end)')" >/dev/null
}

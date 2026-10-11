# shellcheck shell=bash
# Local files: the AniList token (config) and per-anime preferences (state).

CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/ani-sync
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/ani-sync
TOKEN_FILE=$CONFIG_DIR/token
# one line per AniList media id: id <TAB> mode <TAB> query <TAB> provider title
PREFS_FILE=$STATE_DIR/prefs.tsv

PREF_MODE=2 PREF_QUERY=3 PREF_PICK=4

token_load() { [ -s "$TOKEN_FILE" ] && AL_TOKEN=$(<"$TOKEN_FILE"); }

token_save() {
    mkdir -p "$CONFIG_DIR"
    (umask 077 && printf '%s\n' "$1" >"$TOKEN_FILE")
}

token_delete() { rm -f "$TOKEN_FILE"; }

# state_get MEDIA_ID FIELD
state_get() {
    [ -f "$PREFS_FILE" ] || return 0
    awk -F'\t' -v id="$1" -v f="$2" '$1 == id { print $f; exit }' "$PREFS_FILE"
}

# state_set MEDIA_ID FIELD VALUE
state_set() {
    local tmp v=${3//$'\t'/ }
    v=${v//\\/\\\\} # awk -v interprets backslash escapes
    mkdir -p "$STATE_DIR"
    [ -f "$PREFS_FILE" ] || : >"$PREFS_FILE"
    tmp=$(mktemp "$PREFS_FILE.XXXXXX") || return 1
    awk -F'\t' -v OFS='\t' -v id="$1" -v f="$2" -v v="$v" '
        $1 == id { $f = v; found = 1 }
        { print }
        END { if (!found) { $0 = ""; $1 = id; $f = v; print } }
    ' "$PREFS_FILE" >"$tmp" && mv "$tmp" "$PREFS_FILE"
}

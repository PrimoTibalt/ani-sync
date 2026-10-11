# shellcheck shell=bash
# Minimal vim-style TUI toolkit.
# Everything is drawn on fd 3 (/dev/tty) so stdout stays free for data: the
# ani-cli menu helper prints its answer on stdout while drawing on the tty.

C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_REV=$'\e[7m'
C_ACCENT=$'\e[36m' C_WARN=$'\e[33m' C_OK=$'\e[32m'

TUI_ACTIVE=0
TUI_RESIZED=0
TUI_MSG=""   # one-shot message shown in the status line of the next screen
TUI_USER=""  # shown at the right of the title bar
TUI_START=0  # initial cursor (item index) for the next tui_list call

tui_init() {
    exec 3<>/dev/tty || return 1
    TUI_STTY=$(stty -g <&3)
    trap 'TUI_RESIZED=1' WINCH
    tui_resume
}

tui_resume() {
    stty -echo -icanon min 1 time 0 <&3
    printf '\e[?1049h\e[?25l\e[H\e[2J' >&3
    TUI_ACTIVE=1
}

tui_suspend() {
    [ "$TUI_ACTIVE" = 1 ] || return 0
    printf '\e[0m\e[?25h\e[?1049l' >&3
    stty "$TUI_STTY" <&3
    TUI_ACTIVE=0
}

tui_size() {
    local s
    s=$(stty size <&3 2>/dev/null) || s="24 80"
    TUI_ROWS=${s% *} TUI_COLS=${s#* }
    (( TUI_ROWS < 6 )) && TUI_ROWS=6
    (( TUI_COLS < 20 )) && TUI_COLS=20
}

# Reads one key into TUI_K. Named keys: enter esc bs tab up down left right
# home end pgup pgdn resize, control keys as C-<letter>; anything else is the
# literal character.
tui_key() {
    local k rest seq rc
    while :; do
        IFS= read -rsN1 -t 0.3 -u 3 k && break
        rc=$?
        (( rc <= 128 )) && exit 1 # tty is gone
        if [ "$TUI_RESIZED" = 1 ]; then
            TUI_RESIZED=0 TUI_K=resize
            return
        fi
    done
    case "$k" in
        $'\e')
            if ! IFS= read -rsN1 -t 0.02 -u 3 rest; then
                TUI_K=esc
            elif [[ $rest == '[' || $rest == O ]]; then
                IFS= read -rsN1 -t 0.02 -u 3 k
                case "$k" in
                    A) TUI_K=up ;; B) TUI_K=down ;; C) TUI_K=right ;; D) TUI_K=left ;;
                    H) TUI_K=home ;; F) TUI_K=end ;;
                    [0-9])
                        seq=$k
                        while IFS= read -rsN1 -t 0.02 -u 3 k && [[ $k != '~' ]]; do seq+=$k; done
                        case "$seq" in 5) TUI_K=pgup ;; 6) TUI_K=pgdn ;; *) TUI_K=unknown ;; esac
                        ;;
                    *) TUI_K=unknown ;;
                esac
            else
                TUI_K=esc # Alt+key: treat as Esc, drop the key
            fi
            ;;
        $'\n' | $'\r') TUI_K=enter ;;
        $'\x7f' | $'\b') TUI_K=bs ;;
        $'\t') TUI_K=tab ;;
        $'\x02') TUI_K=C-b ;; $'\x04') TUI_K=C-d ;; $'\x06') TUI_K=C-f ;;
        $'\x0c') TUI_K=C-l ;; $'\x0e') TUI_K=C-n ;; $'\x10') TUI_K=C-p ;;
        $'\x15') TUI_K=C-u ;; $'\x17') TUI_K=C-w ;;
        *) TUI_K=$k ;;
    esac
}

# _tui_fit TEXT WIDTH -> FIT: truncated with … or right-padded to WIDTH chars
_tui_fit() {
    local s=$1 w=$2
    if (( w <= 0 )); then FIT=""; return; fi
    (( ${#s} > w )) && s="${s:0:w-1}…"
    printf -v FIT '%s%*s' "$s" $(( w - ${#s} )) ''
}

_tui_line() { BUF+=$'\e['"$1"$';1H\e[2K'"$2"; }

_tui_header() {
    local right="${TUI_USER:+$TUI_USER }"
    _tui_fit " ani-sync › $1" $(( TUI_COLS - ${#right} ))
    _tui_line 1 "${C_REV}${C_ACCENT}${C_BOLD}${FIT}${C_RESET}${C_REV}${C_ACCENT}${right}${C_RESET}"
}

# _tui_footer HINT [STATUS]: status line (defaults to TUI_MSG) + dim key hints
_tui_footer() {
    local status=${2-$TUI_MSG}
    _tui_fit " $status" "$TUI_COLS"
    _tui_line $(( TUI_ROWS - 1 )) "${C_WARN}${FIT}${C_RESET}"
    _tui_fit " $1" "$TUI_COLS"
    _tui_line "$TUI_ROWS" "${C_DIM}${FIT}${C_RESET}"
}

_tui_flush() { printf '%s' "$BUF" >&3; }

tui_loading() {
    tui_size
    BUF=$'\e[H\e[2J'
    _tui_header "$1"
    _tui_line 3 "  ${C_DIM}${2}${C_RESET}"
    _tui_flush
}

tui_help() {
    local body
    body="${C_BOLD}Lists${C_RESET}
  j / k  ↓ / ↑        move down / up (counts work: 5j)
  gg / G              first / last item
  Ctrl-d / Ctrl-u     half page down / up
  Ctrl-f / Ctrl-b     full page down / up
  l / Enter           open / select
  h / q               back (q on Home quits)
  /                   filter: type, Enter keeps it, Esc clears it
  Esc                 clear the filter, otherwise back
  ?                   this help

${C_BOLD}Text input${C_RESET}
  Enter accept · Esc cancel · Backspace · Ctrl-w delete word · Ctrl-u clear

Screen-specific keys are listed at the bottom of each screen."
    tui_prompt "Help" "$body" "any" "press any key to go back"
}

# tui_prompt TITLE BODY KEYS [HINT]: waits for one of the space-separated KEYS
# ("any" accepts every key). Sets TUI_KEY.
tui_prompt() {
    local title=$1 body=$2 keys=$3 hint=${4:-} row line
    while :; do
        tui_size
        BUF=$'\e[H\e[2J'
        _tui_header "$title"
        row=3
        while IFS= read -r line; do
            (( row >= TUI_ROWS - 1 )) && break
            _tui_line "$row" "  $line"
            (( row++ ))
        done <<<"$body"
        _tui_footer "$hint"
        TUI_MSG=""
        _tui_flush
        tui_key
        case "$TUI_K" in resize | C-l) continue ;; esac
        if [ "$keys" = any ] || [[ " $keys " == *" $TUI_K "* ]]; then
            TUI_KEY=$TUI_K
            return 0
        fi
        [ "$TUI_K" = "?" ] && tui_help
    done
}

# tui_input TITLE PROMPT [INITIAL] [MASK]: single-line editor. Sets TUI_INPUT;
# returns 1 when cancelled with Esc. MASK=1 hides the text (for tokens).
tui_input() {
    local title=$1 prompt=$2 text=${3:-} mask=${4:-0} shown w c done=0
    while :; do
        tui_size
        w=$(( TUI_COLS - 6 ))
        shown=$text
        [ "$mask" = 1 ] && shown=${text//?/•}
        (( ${#shown} > w )) && shown="…${shown: -$(( w - 1 ))}"
        BUF=$'\e[?25l\e[H\e[2J'
        _tui_header "$title"
        _tui_line 3 "  ${C_BOLD}${prompt}${C_RESET}"
        _tui_line 5 "  ${C_ACCENT}›${C_RESET} ${shown}"
        _tui_footer "Enter accept · Esc cancel · Ctrl-w delete word · Ctrl-u clear"
        TUI_MSG=""
        BUF+=$'\e[5;'"$(( ${#shown} + 5 ))"$'H\e[?25h'
        _tui_flush
        tui_key
        case "$TUI_K" in
            enter) done=1 ;;
            esc) printf '\e[?25l' >&3; return 1 ;;
            bs) text=${text%?} ;;
            C-u) text="" ;;
            C-w)
                text=${text%"${text##*[![:space:]]}"}
                text=${text%"${text##*[[:space:]]}"}
                ;;
            ?)
                [[ $TUI_K == [[:cntrl:]] ]] && continue
                text+=$TUI_K
                # slurp the rest of a paste in one go instead of redrawing per char
                while IFS= read -rsN1 -t 0.01 -u 3 c; do
                    case "$c" in
                        $'\n' | $'\r') done=1; break ;;
                        [[:cntrl:]]) ;;
                        *) text+=$c ;;
                    esac
                done
                ;;
        esac
        if [ "$done" = 1 ]; then
            printf '\e[?25l' >&3
            TUI_INPUT=$text
            return 0
        fi
    done
}

# tui_list TITLE HINT EXTRA_KEYS ITEM...
# Items are "left<TAB>right" (right part is optional, shown dim and aligned).
# Sets TUI_KEY to "enter", "back" or one of the space-separated EXTRA_KEYS,
# and TUI_SEL to the selected item index (-1 when the list is empty).
tui_list() {
    local title=$1 hint=$2 extra=$3
    shift 3
    local -a items=("$@") vis=()
    local pos=0 top=0 filter="" filtering=0 count="" pending="" h n i k
    local left right lw row sub step counted

    _tui_list_refilter() {
        vis=()
        local f=${filter,,}
        for i in "${!items[@]}"; do
            [[ -z $f || ${items[i],,} == *"$f"* ]] && vis+=("$i")
        done
    }
    _tui_list_refilter
    for n in "${!vis[@]}"; do [ "${vis[n]}" = "$TUI_START" ] && pos=$n; done
    TUI_START=0

    while :; do
        tui_size
        h=$(( TUI_ROWS - 4 ))
        n=${#vis[@]}
        (( pos >= n )) && pos=$(( n - 1 ))
        (( pos < 0 )) && pos=0
        (( pos < top )) && top=$pos
        (( pos >= top + h )) && top=$(( pos - h + 1 ))
        (( top > 0 && top > n - h )) && top=$(( n - h > 0 ? n - h : 0 ))

        BUF=$'\e[H'
        _tui_header "$title"
        if (( filtering )) || [ -n "$filter" ]; then
            sub="${C_ACCENT}/${C_RESET}${filter}"
            (( filtering )) && sub+="${C_ACCENT}▏${C_RESET}"
            sub+="  ${C_DIM}${n}/${#items[@]}${C_RESET}"
        else
            sub="${C_DIM}${#items[@]} item(s)${C_RESET}"
            (( ${#items[@]} == 1 )) && sub="${C_DIM}1 item${C_RESET}"
        fi
        _tui_line 2 " $sub"
        for (( row = 0; row < h; row++ )); do
            i=$(( top + row ))
            if (( i >= n )); then
                if (( n == 0 && row == 0 )); then
                    _tui_line 3 "   ${C_DIM}(nothing here)${C_RESET}"
                else
                    _tui_line $(( row + 3 )) ""
                fi
                continue
            fi
            left=${items[vis[i]]%%$'\t'*}
            right=""
            [[ ${items[vis[i]]} == *$'\t'* ]] && right=${items[vis[i]]#*$'\t'}
            (( ${#right} > TUI_COLS / 2 )) && right="${right:0:TUI_COLS/2-1}…"
            lw=$(( TUI_COLS - 3 - ${#right} - (${#right} ? 2 : 0) ))
            _tui_fit "$left" "$lw"
            if (( i == pos )); then
                _tui_line $(( row + 3 )) "${C_REV}${C_ACCENT} ▶ ${FIT}${right:+  $right}${C_RESET}"
            else
                _tui_line $(( row + 3 )) "   ${FIT}${right:+  ${C_DIM}$right${C_RESET}}"
            fi
        done
        if (( filtering )); then
            _tui_footer "type to filter · Enter keep · Esc clear · ↑/↓ move" ""
        else
            _tui_footer "$hint · ? help"
        fi
        TUI_MSG=""
        _tui_flush

        tui_key
        k=$TUI_K
        [[ $k == resize || $k == C-l ]] && continue

        if (( filtering )); then
            case "$k" in
                enter) filtering=0 ;;
                esc) filtering=0 filter="" ;;
                bs) if [ -z "$filter" ]; then filtering=0; else filter=${filter%?}; fi ;;
                C-w | C-u) filter="" ;;
                up | C-p) (( pos-- )); continue ;;
                down | C-n) (( pos++ )); continue ;;
                ?) [[ $k == [[:cntrl:]] ]] || filter+=$k ;;
            esac
            _tui_list_refilter
            pos=0 top=0
            continue
        fi

        if [[ $k == [1-9] || ( $k == 0 && -n $count ) ]]; then
            count+=$k
            continue
        fi
        step=${count:-1} counted=$count
        count=""
        if [ -n "$extra" ] && [[ " $extra " == *" $k "* ]]; then
            TUI_KEY=$k
            TUI_SEL=${vis[pos]:--1}
            return 0
        fi
        if [ "$pending" = g ]; then
            pending=""
            [ "$k" = g ] && { pos=0; continue; }
        fi
        case "$k" in
            j | down | C-n) (( pos += step )) ;;
            k | up | C-p) (( pos -= step )); (( pos < 0 )) && pos=0 ;;
            g) pending=g ;;
            home) pos=0 ;;
            G | end) if [ -n "$counted" ]; then pos=$(( step - 1 )); else pos=$(( n - 1 )); fi ;;
            C-d) (( pos += h / 2 )) ;;
            C-u) (( pos -= h / 2 )); (( pos < 0 )) && pos=0 ;;
            C-f | pgdn) (( pos += h )); (( top += h )) ;;
            C-b | pgup) (( pos -= h )); (( top -= h )); (( pos < 0 )) && pos=0; (( top < 0 )) && top=0 ;;
            l | enter | right)
                if (( n > 0 )); then
                    TUI_KEY=enter TUI_SEL=${vis[pos]}
                    return 0
                fi
                ;;
            h | left | q)
                TUI_KEY=back TUI_SEL=-1
                return 0
                ;;
            esc)
                if [ -n "$filter" ]; then
                    filter=""
                    _tui_list_refilter
                else
                    TUI_KEY=back TUI_SEL=-1
                    return 0
                fi
                ;;
            /) filtering=1 filter="" ;;
            "?") tui_help ;;
        esac
    done
}

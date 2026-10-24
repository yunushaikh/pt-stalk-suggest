# shellcheck shell=bash
# Recording suggestions and rendering the terminal report.
#
# A rule records one parameter like this:
#   ev "Opened_tables 24/s in window"        # evidence lines, any number
#   ev "Open_tables 4495 of 4495 (100%)"
#   suggest table_open_cache CHANGE Medium "$cur" "$new" "formula" "why"
#
# STATUS: CHANGE (act), REVIEW (look closer / judgement call), OK, INFO
# CONF:   High | Medium | Low

declare -ga R_PARAM=() R_STATUS=() R_CONF=() R_CUR=() R_NEW=() R_EV=() R_FORMULA=() R_WHY=() R_GROUP=()
declare -ga FINDINGS=() FINDINGS_TOP=() CAVEATS=() NOT_APPLICABLE=()
declare -ga _EV=()
RULE_GROUP=""

ev()       { _EV+=("$*"); }
finding()  { FINDINGS+=("$*"); }
finding_top() { FINDINGS_TOP+=("$*"); }   # what most likely explains an incident: listed first
caveat()   { CAVEATS+=("$*"); }
not_applicable() { NOT_APPLICABLE+=("$1 ($2)"); }

suggest() {
    local param=$1 status=$2 conf=$3 cur=$4 new=$5 formula=$6 why=$7
    R_PARAM+=("$param") R_STATUS+=("$status") R_CONF+=("$conf")
    R_CUR+=("$cur") R_NEW+=("$new") R_FORMULA+=("$formula") R_WHY+=("$why") R_GROUP+=("$RULE_GROUP")
    local IFS=$'\x1f'
    R_EV+=("${_EV[*]}")
    _EV=()
}

# Lower a confidence by one step (used for short uptime / short windows)
conf_down() { case $1 in High) echo Medium ;; *) echo Low ;; esac; }

# Shortly after a restart caches are cold and every counter is inflated by
# warm-up (tables being opened, pages read): lower confidence across the board.
apply_uptime_penalty() {
    local up i; up=$(num "$(h uptime)")
    ((up >= 3600)) && return 0
    for i in "${!R_STATUS[@]}"; do
        [[ ${R_STATUS[$i]} == CHANGE || ${R_STATUS[$i]} == REVIEW ]] && R_CONF[$i]=$(conf_down "${R_CONF[$i]}")
    done
    caveat "Uptime under one hour: confidence of every suggestion was lowered one step because warm-up inflates the counters."
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
setup_colors() {
    if [[ ${USE_COLOR:-auto} == always || ( ${USE_COLOR:-auto} == auto && -t 1 ) ]]; then
        C_B=$'\e[1m' C_D=$'\e[2m' C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_C=$'\e[36m' C_0=$'\e[0m'
    else
        C_B='' C_D='' C_R='' C_G='' C_Y='' C_C='' C_0=''
    fi
    # COLUMNS wins so output is reproducible (tests, CI); else the terminal width
    WIDTH=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}
    ((WIDTH > 110)) && WIDTH=110
    ((WIDTH < 80)) && WIDTH=80
}

status_color() {
    case $1 in CHANGE) printf '%s' "$C_R" ;; REVIEW) printf '%s' "$C_Y" ;; OK) printf '%s' "$C_G" ;; *) printf '%s' "$C_C" ;; esac
}

rule_line() { printf '%s\n' "$(printf '%*s' "$WIDTH" '' | tr ' ' "${1:--}")"; }

section() {
    printf '\n%s%s%s\n' "$C_B" "$1" "$C_0"
    rule_line '-'
}

# kv "Label" "value"
kv() { printf '  %-18s %s\n' "$1" "$2"; }

# Wrap text to the report width with a hanging indent
wrap() {
    local indent=$1; shift
    printf '%s\n' "$*" | fold -s -w $((WIDTH - indent)) | sed "2,\$s/^/$(printf '%*s' "$indent" '')/"
}

render_summary() {
    section "Summary"
    local i st order w1=9 w2=7 w3=9
    for i in "${!R_PARAM[@]}"; do
        ((${#R_PARAM[$i]} > w1)) && w1=${#R_PARAM[$i]}
        ((${#R_CUR[$i]} > w2)) && w2=${#R_CUR[$i]}
        ((${#R_NEW[$i]} > w3)) && w3=${#R_NEW[$i]}
    done
    printf "  %s%-${w1}s  %-${w2}s  %-${w3}s  %-7s %-6s%s\n" "$C_B" "Parameter" "Current" "Suggested" "Status" "Conf." "$C_0"
    for order in CHANGE REVIEW INFO OK; do
        for i in "${!R_PARAM[@]}"; do
            st=${R_STATUS[$i]}
            [[ $st == "$order" ]] || continue
            printf "  %-${w1}s  %-${w2}s  %-${w3}s  %s%-7s%s %-6s\n" "${R_PARAM[$i]}" "${R_CUR[$i]}" "${R_NEW[$i]}" \
                "$(status_color "$st")" "$st" "$C_0" "${R_CONF[$i]}"
        done
    done
}

render_details() {
    local show_ok=$1 i st order line
    section "Details (evidence and formulas)"
    for order in CHANGE REVIEW INFO OK; do
        for i in "${!R_PARAM[@]}"; do
            st=${R_STATUS[$i]}
            [[ $st == "$order" ]] || continue
            [[ $st == OK && $show_ok -eq 0 ]] && continue
            printf '\n  %s[%s]%s %s%s%s   %s -> %s   %s(confidence: %s)%s\n' \
                "$(status_color "$st")" "$st" "$C_0" "$C_B" "${R_PARAM[$i]}" "$C_0" \
                "${R_CUR[$i]}" "${R_NEW[$i]}" "$C_D" "${R_CONF[$i]}" "$C_0"
            local first=1
            local -a evs=()
            IFS=$'\x1f' read -r -a evs <<<"${R_EV[$i]}"
            for line in "${evs[@]}"; do
                if ((first)); then printf '    %-10s ' "Evidence"; first=0; else printf '    %-10s ' ""; fi
                wrap 15 "$line"
            done
            [[ -n ${R_FORMULA[$i]} ]] && { printf '    %-10s ' "Formula"; wrap 15 "${R_FORMULA[$i]}"; }
            [[ -n ${R_WHY[$i]} ]] && { printf '    %-10s ' "Why"; wrap 15 "${R_WHY[$i]}"; }
        done
    done
    if [[ $show_ok -eq 0 ]]; then
        printf '\n  %s(OK parameters hidden; use --all to show their evidence)%s\n' "$C_D" "$C_0"
    fi
}

render_findings() {
    ((${#FINDINGS[@]} + ${#FINDINGS_TOP[@]})) || return 0
    section "Other findings (not fixed by configuration)"
    local f
    for f in "${FINDINGS_TOP[@]}"; do printf '  %s*%s ' "$C_R" "$C_0"; wrap 4 "$f"; done
    for f in "${FINDINGS[@]}"; do printf '  * '; wrap 4 "$f"; done
}

render_caveats() {
    ((${#CAVEATS[@]} + ${#NOT_APPLICABLE[@]})) || return 0
    section "Caveats"
    local f
    for f in "${CAVEATS[@]}"; do printf '  * '; wrap 4 "$f"; done
    if ((${#NOT_APPLICABLE[@]})); then
        printf '  * '; wrap 4 "Not applicable here: $(IFS=';'; echo "${NOT_APPLICABLE[*]}" | sed 's/;/; /g')"
    fi
}

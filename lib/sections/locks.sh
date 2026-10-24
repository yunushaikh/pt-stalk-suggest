# shellcheck shell=bash
# "Transactions and locks" section: INNODB_TRX samples (transactions file),
# SHOW ENGINE INNODB STATUS (innodbstatus1/2), performance_schema metadata
# locks (ps-locks-transactions) and pt-stalk's lock-waits summary.

# "YYYY-MM-DD HH:MM:SS" -> seconds, in plain awk (no mktime, so mawk works)
AWK_EPOCH='
    function epoch(s,   d, t, y, m, dd, era, yoe, doy, doe) {
        split(s, d, /[- :]/); y = d[1] + 0; m = d[2] + 0; dd = d[3] + 0
        if (m <= 2) y--
        era = int(y / 400); yoe = y - era * 400
        doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + dd - 1
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
        return (era * 146097 + doe - 719468) * 86400 + d[4] * 3600 + d[5] * 60 + d[6]
    }'

# pt-stalk stamps samples with the host's local time ("TS <epoch> <local>"),
# while trx_started / trx_wait_started / deadlock times are in the MySQL
# server's time zone. CLOCK_OFF = seconds to add to a server time to get host
# time. Host offset comes from the TS line itself; server offset from
# time_zone / system_time_zone when unambiguous, else from the newest
# transaction (rounded to 15 minutes, as every time zone is).
clock_offset() {
    local tsfile=$1 tsv=$2 host_off server_off="" tz=${VARS[time_zone]:-SYSTEM} stz=${VARS[system_time_zone]:-}
    host_off=$(awk "$AWK_EPOCH"'/^TS / { d = epoch($3 " " $4) - int($2); printf "%d\n", (d >= 0 ? int((d + 450) / 900) : -int((-d + 450) / 900)) * 900; exit }' "$tsfile")
    if [[ $tz =~ ^([+-])([0-9]{1,2}):([0-9]{2})$ ]]; then
        server_off=$(( (10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60) * (${BASH_REMATCH[1]}1) ))
    elif [[ $tz == SYSTEM ]]; then
        case $stz in
            UTC|GMT|UCT|Z|Etc/UTC|Universal) server_off=0 ;;
            PDT) server_off=-25200 ;; PST) server_off=-28800 ;; MDT) server_off=-21600 ;; MST) server_off=-25200 ;;
            EDT) server_off=-14400 ;; EST) server_off=-18000 ;; CDT) server_off=-18000 ;;
            BST|CET|WAT) server_off=3600 ;; CEST|EET|SAST) server_off=7200 ;; EEST|MSK) server_off=10800 ;;
            JST|KST) server_off=32400 ;; SGT|HKT|AWST) server_off=28800 ;; AEST) server_off=36000 ;; AEDT) server_off=39600 ;;
            NZST) server_off=43200 ;; NZDT) server_off=46800 ;;
            [+-][0-9][0-9]) server_off=$(( 10#${stz:1} * 3600 * (${stz:0:1}1) )) ;;
        esac
    fi
    if [[ -n $server_off && -n $host_off ]]; then
        CLOCK_OFF=$((host_off - server_off)); CLOCK_HOW="time_zone=$tz, system_time_zone=$stz"
    else
        # newest transaction started just before its sample
        CLOCK_OFF=$(awk -F'\t' "$AWK_EPOCH"'$5 ~ /^[0-9]{4}-/ { d = epoch($2) - epoch($5); if (m == "" || d < m) m = d }
            END { m += 0; printf "%d\n", (m >= 0 ? int((m + 450) / 900) : -int((-m + 450) / 900)) * 900 }' "$tsv")
        CLOCK_HOW="estimated from the newest transactions (system_time_zone=$stz is ambiguous)"
    fi
}

# One TSV row per transaction per sample:
#   sample sample_time trx_id state started wait_started thread rows_locked
#   rows_modified lock_structs isolation op_state query
AWK_TRX='
        function flush() {
            if (id != "") {
                gsub(/[\t\r]/, " ", q); gsub(/  +/, " ", q); sub(/^ /, "", q)
                printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sample, when, id, st, started, waits, thr, rl, rm, ls, iso, op, q
            }
            id = st = started = waits = thr = rl = rm = ls = iso = op = q = ""; inq = 0
        }
        /^TS / { flush(); sample++; when = $3 " " $4; intrx = 0; next }
        /^\*+ [0-9]+\. row \*+$/ { flush(); intrx = 0; next }
        match($0, /^ *[a-z_]+: /) {
            key = $0; sub(/^ */, "", key); sub(/:.*/, "", key); val = substr($0, RLENGTH + 1)
            if (key !~ /^trx_/) { inq = 0; next }     # data_locks / lock_waits rows are not transactions
            inq = 0
            if (key == "trx_id") id = val
            else if (key == "trx_state") st = val
            else if (key == "trx_started") started = val
            else if (key == "trx_wait_started") waits = val
            else if (key == "trx_mysql_thread_id") thr = val
            else if (key == "trx_rows_locked") rl = val
            else if (key == "trx_rows_modified") rm = val
            else if (key == "trx_lock_structs") ls = val
            else if (key == "trx_isolation_level") iso = val
            else if (key == "trx_operation_state") op = val
            else if (key == "trx_query") { q = val; inq = 1 }
            next
        }
        inq { q = q " " $0 }
        END { flush() }'
parse_innodb_trx() {
    # On 8.0+ the same file also holds performance_schema.data_locks, one row
    # per lock (gigabytes during a lock storm). Its fields are UPPERCASE
    # ("ENGINE_LOCK_ID: ..."), INNODB_TRX fields are trx_*: dropping the
    # uppercase field lines with grep first is ~5x faster than awk alone.
    # TRX_PREFILTER=0 skips the grep (used by the tests to compare both paths).
    if [[ ${TRX_PREFILTER:-1} == 1 ]]; then
        grep -hvE '^ *[A-Z_]+: ' "$@" | awk "$AWK_TRX"
    else
        awk "$AWK_TRX" "$@"
    fi
}

# What a thread was doing at its last processlist sample: "state: statement"
thread_doing() {
    local f=$WORK/processlist.tsv
    [[ -s $f ]] || return 0
    awk -F'\t' -v id="$1" '$2 == id { st = $8; q = $9; c = $6; t = $7 }
        END { if (c != "") { if (q == "" || q == "NULL") printf "%s for %ss, no statement (idle)", c, t; else printf "%s%s%ss: %s", (st != "" ? st : c), (st != "" ? " for " : " "), t, substr(q, 1, 110) } }' "$f"
}

# Plain meaning of an InnoDB lock description
lock_meaning() {
    case $1 in
        *"insert intention"*) echo "an INSERT waiting for a gap lock that another statement took while scanning (REPEATABLE READ locks the gaps between rows it reads)" ;;
        *"locks rec but not gap"*) echo "waiting for one row that another transaction has locked" ;;
        *"locks gap before rec"*) echo "waiting for a gap lock (protects the space between rows)" ;;
        *"lock_mode X"*) echo "waiting to lock a row and the gap before it (next-key lock), as UPDATE/DELETE do under REPEATABLE READ" ;;
        *"lock mode S"*) echo "waiting for a shared (read) lock, e.g. a foreign key check or SELECT ... FOR SHARE" ;;
        *"AUTO-INC"*) echo "waiting for the table's auto-increment lock" ;;
        *"TABLE LOCK"*) echo "waiting for a table-level InnoDB lock" ;;
        *) echo "" ;;
    esac
}

render_locks_section() {
    local -a trxf ibs psl lw
    mapfile -t trxf < <(sampled_files transactions)
    local p f
    for p in "${CAPTURES[@]}"; do for f in "$p"-innodbstatus*; do [[ -r $f ]] && ibs+=("$f"); done; done
    mapfile -t psl < <(sampled_files ps-locks-transactions)
    mapfile -t lw < <(sampled_files lock-waits)
    ((${#trxf[@]} + ${#ibs[@]})) || return 0
    section "Transactions and locks"
    printf '  '; wrap 2 "How to read this: InnoDB locks the rows a statement changes, and under REPEATABLE READ also the rows (and the gaps between them) it reads to find them, until the transaction commits. A statement that has to read a whole table to change one row therefore locks the whole table, and everything else that writes to it waits."
    echo

    # pt-stalk 8.0+ also dumps every performance_schema.data_locks row into the
    # transactions file; with millions of row locks that takes longer than a
    # second, collections overlap, and the dump itself loads the server
    local big_mb=0 tf
    for tf in "${trxf[@]}"; do big_mb=$(( big_mb + $(stat -c %s "$tf") / 1048576 )); done
    ((big_mb > 500)) && caveat "The transactions files are ${big_mb} MB: pt-stalk dumped every row of performance_schema.data_locks each second. Such dumps take longer than a second, so samples overlap (counts here are de-duplicated per sample) and they add load to an already busy server. With millions of row locks, --skip-collection=lock-waits removes the slowest query; adding transactions also avoids the data_locks dump but loses INNODB_TRX (InnoDB status still lists the transactions)."

    local tsv=$WORK/innodb_trx.tsv
    : >"$tsv"
    ((${#trxf[@]})) && parse_innodb_trx "${trxf[@]}" >"$tsv"
    CLOCK_OFF=0 CLOCK_HOW=""
    [[ -s $tsv ]] && clock_offset "${trxf[0]}" "$tsv"

    if [[ -s $tsv ]]; then
        # ---- how many open / waiting at once
        local summary
        # each transaction once per sample: when a slow collection overlaps the
        # next one, pt-stalk writes the same rows into a sample more than once
        summary=$(awk -F'\t' '!(($1, $3) in seen) { seen[$1, $3] = 1; n[$1]++; if ($4 == "LOCK WAIT") w[$1]++; when[$1] = $2 }
            END { for (s in n) { if (n[s] > mn) mn = n[s]; if (w[s] > mw || (w[s] == mw && w[s] && s + 0 < ats)) { mw = w[s]; at = when[s]; ats = s + 0 } }
                  printf "up to %d open at once; up to %d waiting for a row lock at the same time%s", mn, mw, (mw ? " (" at ")" : "") }' "$tsv")
        kv "Transactions" "$summary"
        local longest
        longest=$(awk -F'\t' -v off="$CLOCK_OFF" "$AWK_EPOCH"'$4 == "LOCK WAIT" && $6 ~ /^[0-9]{4}-/ { w = epoch($2) - epoch($6) - off; if (w > m) { m = w; t = $3 } }
            END { if (m) printf "%d\t%s", m, t }' "$tsv")
        if [[ -n $longest ]]; then
            local lw_s lw_t lwt=${VARS[innodb_lock_wait_timeout]:-}
            IFS=$'\t' read -r lw_s lw_t <<<"$longest"
            if [[ -n $lwt ]] && ((lw_s >= lwt)); then
                kv "Longest lock wait" "${lw_s}s (trx $lw_t): it reached innodb_lock_wait_timeout = ${lwt}s, so statements fail with ERROR 1205 (Lock wait timeout exceeded) and the application sees errors, not just slowness"
                finding_top "Lock waits reached innodb_lock_wait_timeout (${lwt}s): statements were failing with ERROR 1205. See Transactions and locks."
            else
                kv "Longest lock wait" "${lw_s}s (trx $lw_t); innodb_lock_wait_timeout = ${lwt:-?}s"
            fi
        fi

        # ---- per transaction, at its oldest
        local agg=$WORK/innodb_trx_agg.tsv
        awk -F'\t' -v off="$CLOCK_OFF" "$AWK_EPOCH"'
            $5 !~ /^[0-9]{4}-/ { next }
            {
                age = epoch($2) - epoch($5) - off; w = ($6 ~ /^[0-9]{4}-/) ? epoch($2) - epoch($6) - off : 0
                k = $3
                if (!(k in a) || age > a[k]) { a[k] = age; st[k] = $4; thr[k] = $7; op[k] = $12 }
                if ($8 + 0 > rl[k]) rl[k] = $8 + 0
                if ($9 + 0 > rm[k]) rm[k] = $9 + 0
                if (w > mw[k]) mw[k] = w
                if ($13 != "NULL" && $13 != "") q[k] = $13
                if (!(k in iso)) iso[k] = $11
            }
            END { for (k in a) printf "%s\t%d\t%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s\n", k, a[k], st[k], thr[k], rl[k], rm[k], mw[k], op[k], iso[k], q[k] }' "$tsv" >"$agg"

        echo
        printf '  %sLongest-open transactions%s (age at the last sample they were seen)\n' "$C_B" "$C_0"
        local id age st thr rl rm mw op iso q n=0
        while IFS=$'\t' read -r id age st thr rl rm mw op iso q; do
            n=$((n + 1))
            printf '    %s%5ss%s  trx %s  thread %s  %s%s  rows locked %s, modified %s\n' "$C_B" "$age" "$C_0" "$id" "$thr" "$st" "${op:+ ($op)}" "$(human_num "$rl")" "$(human_num "$rm")"
            printf '           '; wrap 11 "${q:-(no statement running: the transaction is open but idle)}"
        done < <(awk -F'\t' -v min="$LONG_QUERY_SECS" "$AWK_FINGERPRINT"'$2 >= min { print fingerprint($10) "\t" $0 }' "$agg" |
                 sort -t$'\t' -k3,3nr | awk -F'\t' '++shape[$1] <= 3 && shown++ < 8 { sub(/^[^\t]*\t/, ""); print }')
        ((n)) || echo "    none open for ${LONG_QUERY_SECS}s or longer"
        local more; more=$(awk -F'\t' -v min="$LONG_QUERY_SECS" '$2 >= min' "$agg" | wc -l)
        ((more > n)) && printf '    %s(%s transactions open %ss or longer in total; at most 3 per statement shape are listed)%s\n' "$C_D" "$more" "$LONG_QUERY_SECS" "$C_0"

        # ---- statements that lock far more rows than they change
        local big
        big=$(awk -F'\t' '$5 >= 10000 && $5 >= 100 * ($6 + 1)' "$agg" | sort -t$'\t' -k5,5nr | head -3)
        if [[ -n $big ]]; then
            echo
            printf '  %sStatements that lock far more rows than they change%s\n' "$C_R" "$C_0"
            while IFS=$'\t' read -r id age st thr rl rm mw op iso q; do
                local tbl cols
                tbl=$(printf '%s' "$q" | grep -oiE '^(update|delete +from|delete) +`?[A-Za-z0-9_$.]+' | awk '{print $NF}' | tr -d '`')
                cols=$(printf '%s' "$q" | sed -nE 's/.*[Ww][Hh][Ee][Rr][Ee] (.*)/\1/p' | grep -oE '`?[A-Za-z_][A-Za-z0-9_]*`? *(=|IN |in |LIKE |like )' | sed -E 's/[` ]|=|IN|in|LIKE|like//g' | awk '!s[$0]++' | paste -sd, -)
                printf '    trx %s (thread %s): %s rows locked, %s modified, %s, open %ss\n' "$id" "$thr" "$(human_num "$rl")" "$(human_num "$rm")" "$iso" "$age"
                if [[ $q =~ ^[[:space:]]*\(?[[:space:]]*([Uu][Pp][Dd][Aa][Tt][Ee]|[Dd][Ee][Ll][Ee][Tt][Ee]|[Ii][Nn][Ss][Ee][Rr][Tt]|[Rr][Ee][Pp][Ll][Aa][Cc][Ee]) ]]; then
                    printf '      '; wrap 6 "${q:0:300}"
                    printf '      '; wrap 6 "Meaning: to find the rows to change, this statement reads (and under $iso locks) about $(human_num "$rl") rows. That usually means no index matches its WHERE clause${cols:+ (columns: $cols)}, so it scans ${tbl:-the table} and blocks every other write to it until it commits."
                    finding_top "A statement locks $(human_num "$rl") rows to change $(human_num "$rm") (trx $id, ${tbl:-table}): it most likely scans the table because no index matches its WHERE clause${cols:+ on $cols}. Check with EXPLAIN and add an index${cols:+ on ($cols)}; until then every write to ${tbl:-the table} queues behind it. See Transactions and locks."
                else
                    printf '      now running: %s\n' "${q:-nothing (idle)}"
                    printf '      '; wrap 6 "Meaning: an earlier statement in this transaction took the locks, and the transaction is still open while it does something else. It blocks every write that needs those rows until the application commits or rolls back. Find what the application does between that write and its COMMIT."
                    finding_top "Transaction $id (thread $thr) holds $(human_num "$rl") row locks from an earlier statement and stays open (now: ${q:-idle}): it blocks writers until it commits. See Transactions and locks."
                fi
            done <<<"$big"
        fi

        # ---- open but idle (application did not commit)
        local idle
        idle=$(awk -F'\t' -v min="$LONG_QUERY_SECS" '$2 >= min && ($10 == "" || $10 == "NULL") && $3 == "RUNNING"' "$agg" | sort -t$'\t' -k2,2nr | head -3)
        if [[ -n $idle ]]; then
            echo
            printf '  %sTransactions open but doing nothing%s\n' "$C_Y" "$C_0"
            while IFS=$'\t' read -r id age st thr rl rm mw op iso q; do
                printf '    trx %s  thread %s  open %ss, holds %s row locks\n' "$id" "$thr" "$age" "$(human_num "$rl")"
            done <<<"$idle"
            printf '    '; wrap 4 "Meaning: the application started a transaction and has not committed it; it keeps every lock it took. Look at the processlist for these thread ids (Command: Sleep) and at the application code path."
        fi
    fi

    # ---- what the waiters wait on (InnoDB status)
    if ((${#ibs[@]})); then
        echo
        printf '  %sWhat waiting transactions are waiting for%s (SHOW ENGINE INNODB STATUS)\n' "$C_B" "$C_0"
        local waits
        waits=$(awk '
            FNR == 1 { if (cur > maxw) maxw = cur; cur = 0 }
            /TRX HAS BEEN WAITING/ { cur++; n = $6 + 0; if (n > maxs) maxs = n; grab = 1; next }
            grab && /^(RECORD LOCKS|TABLE LOCK)/ {
                tbl = $0; sub(/.* of table /, "", tbl); sub(/ trx id.*/, "", tbl); sub(/^TABLE LOCK table /, "", tbl)
                idx = "-"; if ($0 ~ / index /) { idx = $0; sub(/.* index /, "", idx); sub(/ of table.*/, "", idx) }
                mode = $0; sub(/.* trx id [0-9]+ /, "", mode); sub(/ waiting$/, "", mode)
                if ($0 ~ /^TABLE LOCK/) mode = "TABLE LOCK " mode
                key = tbl "\t" idx "\t" mode; c[key]++; grab = 0
            }
            END {
                if (cur > maxw) maxw = cur
                printf "#max\t%d\t%d\n", maxw, maxs
                for (k in c) printf "%d\t%s\n", c[k], k
            }' "${ibs[@]}")
        local maxw maxs
        read -r _ maxw maxs < <(printf '%s\n' "$waits" | grep '^#max' | tr '\t' ' ')
        if ((maxw > 0)); then
            kv "Waiting" "up to $maxw transactions waiting in one status snapshot; longest wait shown ${maxs}s"
            local cnt tb ix md
            while IFS=$'\t' read -r cnt tb ix md; do
                printf '    %5s x  %s  index %s\n' "$cnt" "$tb" "$ix"
                printf '             %s\n' "$md"
                local mean; mean=$(lock_meaning "$md")
                [[ -n $mean ]] && { printf '             '; wrap 13 "= $mean"; }
            done < <(printf '%s\n' "$waits" | grep -v '^#max' | sort -t$'\t' -k1,1nr | head -5)
            if printf '%s\n' "$waits" | grep -v '^#max' | awk -F'\t' '$3 == "PRIMARY" && $4 !~ /insert intention/' | grep -q .; then
                printf '    '; wrap 4 "Waits on index PRIMARY: these statements look rows up through the primary key (the table itself), so they are not using a secondary index on the columns in their WHERE clause."
            fi
        else
            kv "Waiting" "no transaction was waiting for a lock in the status snapshots"
        fi

        # ---- latest deadlock
        local dl
        dl=$(awk '
            /^LATEST DETECTED DEADLOCK/ { indl = 1; t = ""; next }
            indl && /^(TRANSACTIONS|------------)$/ && t != "" && seen_body { indl = 0 }
            indl && /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}/ && t == "" { t = $1 " " $2; next }
            indl && /^\*\*\* \([0-9]+\) TRANSACTION:/ { seen_body = 1; getline; tx = $0; sub(/,.*/, "", tx); want = 1; next }
            indl && want && /^MySQL thread id/ { getline; s = substr($0, 1, 90); if (!((t, s) in qs)) { qs[t, s] = 1; q[t] = q[t] (q[t] ? " || " : "") s }; want = 0; next }
            indl && /^RECORD LOCKS/ { tb = $0; sub(/.* of table /, "", tb); sub(/ trx id.*/, "", tb); tabs[t] = (index(tabs[t], tb) ? tabs[t] : tabs[t] (tabs[t] ? ", " : "") tb) }
            indl && /^\*\*\* WE ROLL BACK TRANSACTION/ { rb[t] = $0; sub(/^\*\*\* WE ROLL BACK /, "", rb[t]) }
            END { for (k in tabs) printf "%s\t%s\t%s\t%s\n", k, tabs[k], rb[k], q[k] }' "${ibs[@]}" | sort -u | tail -1)
        if [[ -n $dl ]]; then
            local dt dtab drb dq
            IFS=$'\t' read -r dt dtab drb dq <<<"$dl"
            echo
            local rel=""
            local first_ts last_ts
            first_ts=$(awk '/^TS /{ print $3 " " $4; exit }' "${trxf[0]:-${ibs[0]}}" 2>/dev/null)
            if [[ -n $first_ts ]]; then
                rel=$(awk -v off="${CLOCK_OFF:-0}" "$AWK_EPOCH"' BEGIN { d = epoch(ARGV[1]) + off - epoch(ARGV[2]); ARGV[1] = ARGV[2] = ""
                    if (d >= -2) print "during the capture"; else if (d > -3600) printf "%d s before the first capture\n", -d; else print "more than an hour before the capture" }' "$dt" "$first_ts")
            fi
            kv "Latest deadlock" "$dt${rel:+ ($rel)} on $dtab; InnoDB rolled back ${drb,,}"
            printf '    '; wrap 4 "Statements: $dq"
            printf '    '; wrap 4 "Meaning: two transactions each held a lock the other needed. InnoDB cancelled one so the other could finish; the application gets error 1213 and should retry. Occasional deadlocks are normal; frequent ones need a consistent order of row access or better indexes."
        fi

        # ---- hot internal latches
        local sem
        sem=$(awk '/has waited at/ { w = $0; sub(/.*has waited at /, "", w); sub(/ for .*/, "", w); s = $0; sub(/.* for /, "", s); sub(/ seconds.*/, "", s)
                c[w]++; if (s + 0 > m[w]) m[w] = s + 0 }
            END { for (k in c) printf "%d\t%s\t%.0f\n", c[k], k, m[k] }' "${ibs[@]}" | sort -t$'\t' -k1,1nr | head -3)
        if [[ -n $sem ]]; then
            echo
            printf '  %sInternal latch waits%s (SEMAPHORES)\n' "$C_B" "$C_0"
            local c w m area
            while IFS=$'\t' read -r c w m; do
                case $w in
                    lock0*) area="the InnoDB lock system: too many row locks being created and checked" ;;
                    buf0*) area="buffer pool pages: a hot page or buffer pool contention" ;;
                    btr0*|row0*) area="an index tree: a hot index page" ;;
                    trx0*) area="the transaction system (undo, purge, many concurrent transactions)" ;;
                    log0*) area="the redo log" ;;
                    dict0*) area="the data dictionary (opening tables, DDL)" ;;
                    *) area="" ;;
                esac
                printf '    %5s waits at %s (longest %ss)%s\n' "$c" "$w" "$m" "${area:+: $area}"
            done <<<"$sem"
            printf '    '; wrap 4 "Meaning: threads queued on an InnoDB internal latch, a short-term lock on an in-memory structure. Many waits in the same place show what is contended."
        fi
    fi

    # ---- metadata locks (performance_schema)
    if ((${#psl[@]})); then
        local mdl
        mdl=$(awk '
            /^select .*metadata_locks/ { inml = 1; snap++; next }
            /^select / { inml = 0; next }
            !inml { next }
            /^ *processlist_id:/ { pid = $2 }
            /^ *OBJECT_TYPE:/ { ot = $2 }
            /^ *OBJECT_SCHEMA:/ { sch = $2 } /^ *OBJECT_NAME:/ { obj = $2 } /^ *LOCK_TYPE:/ { lt = $2 }
            /^ *LOCK_STATUS:/ {
                if (ot != "TABLE") next
                k = sch "." obj
                if ($2 == "PENDING") { psnap[snap]++; if (!((k, pid, lt) in pseen)) { pseen[k, pid, lt] = 1; pc[k, lt]++; ptypes[k] = ptypes[k] (index(ptypes[k], lt) ? "" : " " lt); waiting[k] = waiting[k] (index(" " waiting[k] " ", " " pid " ") ? "" : " " pid) } }
                else { gsnap[snap]++; gr[k, pid] = (index(gr[k, pid], lt) ? gr[k, pid] : gr[k, pid] (gr[k, pid] ? "/" : "") lt); if (!((k, pid) in gseen)) { gseen[k, pid] = 1; holders[k] = holders[k] " " pid } }
            }
            END {
                # per snapshot (one per second), not summed across snapshots
                for (i in gsnap) if (gsnap[i] > ng) ng = gsnap[i]
                for (i in psnap) if (psnap[i] > np) np = psnap[i]
                printf "#\t%d\t%d\n", ng, np
                for (k in ptypes) {
                    n = split(ptypes[k], t, " "); desc = ""
                    for (i = 1; i <= n; i++) desc = desc (desc ? ", " : "") pc[k, t[i]] " x " t[i]
                    m = split(holders[k], hp, " "); hl = ""
                    for (i = 1; i <= m && i <= 6; i++) hl = hl (hl ? " " : "") hp[i] "=" gr[k, hp[i]]
                    printf "%s\t%s\t%s\t%s\n", k, desc, hl, waiting[k]
                }
            }' "${psl[@]}")
        local ng np
        read -r _ ng np < <(printf '%s\n' "$mdl" | grep '^#' | tr '\t' ' ')
        echo
        if ((np > 0)); then
            local nwait; nwait=$(printf '%s\n' "$mdl" | grep -v '^#' | awk -F'\t' '{ n += split($4, a, " ") } END { print n + 0 }')
            printf '  %sMetadata (table-level) lock waits%s: %s session(s) waiting (performance_schema.metadata_locks)\n' "$C_R" "$C_0" "$nwait"
            finding_top "Metadata lock wait: $nwait session(s) could not use a table because of a table-level lock (for example an ALTER TABLE waiting behind an open transaction). See Transactions and locks."
            local obj desc hold waiting hp tid lt doing
            while IFS=$'\t' read -r obj desc hold waiting; do
                printf '    %s%s%s: waiting requests %s\n' "$C_B" "$obj" "$C_0" "$desc"
                for hp in $hold; do
                    tid=${hp%%=*} lt=${hp#*=}
                    doing=$(thread_doing "$tid")
                    printf '      holds   thread %-8s %-28s %s\n' "$tid" "$lt" "$doing"
                done
                for tid in $waiting; do
                    [[ " $hold " == *" $tid="* ]] && continue
                    doing=$(thread_doing "$tid")
                    printf '      waits   thread %-8s %-28s %s\n' "$tid" "" "$doing"
                done | head -6
            done < <(printf '%s\n' "$mdl" | grep -v '^#')
            printf '    '; wrap 4 "Meaning: a session asked for a table-level lock that conflicts with one another session holds. Usually an ALTER TABLE (it needs EXCLUSIVE) waits for an open transaction that read or wrote the table (SHARED_READ / SHARED_WRITE) to finish, and every new query on that table then queues behind the ALTER. The fix is to end the holding transaction (commit, or kill it) or run DDL when no long transactions are open."
        else
            kv "Metadata locks" "up to $(human_num "$ng") table locks held in one snapshot, none waiting (performance_schema.metadata_locks)"
        fi
    fi

    # ---- who blocks whom (pt-stalk lock-waits)
    if ((${#lw[@]})); then
        local total skipped blockers
        total=$(grep -hc '^TS ' "${lw[@]}" | awk '{ s += $1 } END { print s + 0 }')
        skipped=$(grep -hc 'Lock collection already running' "${lw[@]}" | awk '{ s += $1 } END { print s + 0 }')
        blockers=$(awk '/who_blocks:/ { w = $0; sub(/.*who_blocks: /, "", w) } /num_waiters:/ { n = $2; if (n > m[w]) m[w] = n }
            /max_wait_time:/ { t = $2; if (t > mt[w]) mt[w] = t }
            END { for (k in m) printf "%d\t%s\t%d\n", m[k], k, mt[k] }' "${lw[@]}" | sort -t$'\t' -k1,1nr | head -5)
        echo
        if [[ -n $blockers ]]; then
            printf '  %sWho blocks whom%s (pt-stalk lock-waits)\n' "$C_B" "$C_0"
            local nw who mt
            while IFS=$'\t' read -r nw who mt; do
                local bt; bt=$(printf '%s' "$who" | awk '{ print $2 }')
                printf '    %s blocks up to %s transactions (longest wait %ss)\n' "$who" "$nw" "$mt"
                local doing; doing=$(thread_doing "$bt"); [[ -n $doing ]] && { printf '      now: '; wrap 11 "$doing"; }
            done <<<"$blockers"
        elif ((skipped > 0)); then
            kv "Who blocks whom" "not available: in $skipped of $total samples pt-stalk skipped it because its previous lock query was still running"
            printf '    '; wrap 4 "The lock-wait query (sys / data_lock_waits joined with INNODB_TRX) did not finish while millions of row locks were held. Blockers above are inferred from rows locked per transaction instead."
            caveat "pt-stalk's lock-waits collection did not finish (\"Lock collection already running\" in $skipped of $total samples), so who-blocks-whom comes from INNODB_TRX and InnoDB status instead."
        else
            kv "Who blocks whom" "no lock waits recorded by pt-stalk"
        fi
    fi

    # ---- probable blockers when lock-waits are missing: biggest lock holders
    if [[ -s ${WORK}/innodb_trx_agg.tsv ]] && [[ -z ${blockers:-} ]]; then
        local holders
        holders=$(awk -F'\t' '$5 > 0' "$WORK/innodb_trx_agg.tsv" | sort -t$'\t' -k5,5nr | head -5)
        if [[ -n $holders ]]; then
            echo
            printf '  %sTransactions holding the most row locks%s (likely blockers)\n' "$C_B" "$C_0"
            local id age st thr rl rm mw op iso q
            while IFS=$'\t' read -r id age st thr rl rm mw op iso q; do
                printf '    trx %-12s thread %-10s %8s rows locked  open %5ss  %s\n' "$id" "$thr" "$(human_num "$rl")" "$age" "$st"
            done <<<"$holders"
        fi
    fi

    echo
    printf '  %sFiles%s  ' "$C_D" "$C_0"; wrap 9 "$(files_of transactions innodbstatus1 innodbstatus2 ps-locks-transactions lock-waits)"
}

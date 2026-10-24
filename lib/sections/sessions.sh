# shellcheck shell=bash
# "Sessions and queries" section, from the processlist samples (one
# SHOW FULL PROCESSLIST per second, vertical format).

LONG_QUERY_SECS=${LONG_QUERY_SECS:-10}

# Statement shape: literals replaced by ?, value lists collapsed. Portable awk
# (gawk and mawk): \047 is a single quote; numbers are replaced only when not
# part of a word.
AWK_FINGERPRINT='
    function numq(q,   out) {
        out = ""; q = " " q
        while (match(q, /[^A-Za-z0-9_][0-9]+(\.[0-9]+)?/)) { out = out substr(q, 1, RSTART) "?"; q = substr(q, RSTART + RLENGTH) }
        return substr(out q, 2)
    }
    function fingerprint(q) {
        # a quoted literal may contain \x escapes or a doubled quote (\047\047)
        gsub(/\047([^\047\\]|\\.|\047\047)*\047/, "?", q); gsub(/"([^"\\]|\\.|"")*"/, "?", q)
        q = numq(q)
        gsub(/\( *\?( *, *\?)* *\)/, "(?+)", q); gsub(/(\(\?\+\) *, *)+\(\?\+\)/, "(?+)", q)
        gsub(/ +/, " ", q)
        return q
    }'

# Flatten every processlist sample into one TSV row per session:
#   sample  id  user  host  db  command  time  state  info
# The Info field (the SQL) can span many lines; it is joined into one line.
parse_processlist() {
    awk '
        function flush() {
            if (id != "") {
                gsub(/[\t\r]/, " ", info); gsub(/  +/, " ", info); sub(/^ /, "", info); sub(/ $/, "", info)
                printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sample, id, user, host, db, cmd, t, state, info
            }
            id = ""; user = ""; host = ""; db = ""; cmd = ""; t = ""; state = ""; info = ""; ininfo = 0
        }
        /^TS / { flush(); sample++; next }
        /^\*+ [0-9]+\. row \*+$/ { flush(); next }
        match($0, /^ *(Id|User|Host|db|Command|Time|State|Info|Time_ms|Rows_sent|Rows_examined): /) {
            key = $0; sub(/^ */, "", key); sub(/:.*/, "", key)
            val = substr($0, RLENGTH + 1)
            ininfo = 0
            if (key == "Id") id = val
            else if (key == "User") user = val
            else if (key == "Host") { host = val; sub(/:[0-9]+$/, "", host) }
            else if (key == "db") db = val
            else if (key == "Command") cmd = val
            else if (key == "Time") t = val
            else if (key == "State") state = val
            else if (key == "Info") { info = val; ininfo = 1 }
            next
        }
        ininfo { info = info " " $0 }
        END { flush() }' "$@"
}

# Is this row real application work? Drops sleeping/system sessions and
# pt-stalk's own collection queries.
ACTIVE_FILTER='
    function active() {
        if ($6 == "Sleep" || $6 == "Daemon" || $6 ~ /^Binlog Dump/ || $6 == "Killed") return 0
        if ($3 == "system user" || $3 == "event_scheduler") return 0
        if ($9 == "" || $9 == "NULL") return 0
        if ($9 ~ /^(SHOW |show |SELECT SQL_NO_CACHE|select t\.processlist_id|SELECT \* FROM (INFORMATION_SCHEMA|performance_schema|information_schema))/) return 0
        if ($9 ~ /^select (@@version_comment limit 1|\$\$)$/) return 0   # mysql client connecting
        return 1
    }'

# Plain-language meaning of the most common thread states
state_meaning() {
    case $1 in
        "Searching rows for update") echo "an UPDATE/DELETE is reading rows to find the ones to change; long times mean it scans many rows or waits for row locks held by others" ;;
        "updating") echo "changing rows; long times usually mean waiting for row locks" ;;
        "update") echo "an INSERT is adding rows; long times usually mean waiting for locks" ;;
        "executing"|"Sending data") echo "running the query and reading rows" ;;
        "Waiting for table metadata lock") echo "waiting to use the table at all: another session holds a table-level lock (an ALTER/DDL, or a long open transaction that touched the table)" ;;
        "Waiting for table level lock") echo "waiting for a whole-table lock (MyISAM table or LOCK TABLES)" ;;
        "Waiting for global read lock") echo "all writes are paused by FLUSH TABLES WITH READ LOCK, usually a backup" ;;
        "Waiting for commit lock") echo "commits are paused by a backup lock" ;;
        "Waiting for table flush") echo "waiting for FLUSH TABLES to finish, which itself waits for long queries on the table" ;;
        "waiting for handler commit") echo "committing: writing redo and binary log, or waiting for Group Replication certification" ;;
        "System lock") echo "acquiring an internal table lock; long times point to storage-engine or replication waits" ;;
        "Opening tables") echo "opening table handles; many sessions here means the table cache is too small" ;;
        "statistics"|"preparing"|"optimizing") echo "planning the query" ;;
        "Creating sort index"|"Sorting result") echo "sorting rows (ORDER BY/GROUP BY without a suitable index)" ;;
        "Copying to tmp table"|"converting HEAP to ondisk") echo "building an internal temporary table" ;;
        "query end"|"closing tables"|"freeing items"|"cleaning up") echo "finishing the statement; many sessions here point to slow commits or log flushes" ;;
        "Waiting for semaphore"|"waiting for semaphore") echo "waiting for an InnoDB internal latch" ;;
        *) echo "" ;;
    esac
}

render_sessions_section() {
    local -a pls
    mapfile -t pls < <(sampled_files processlist)
    ((${#pls[@]})) || return 0
    local tsv=$WORK/processlist.tsv
    parse_processlist "${pls[@]}" >"$tsv"
    [[ -s $tsv ]] || return 0
    section "Sessions and queries (processlist)"

    local samples; samples=$(awk -F'\t' 'END { print $1 + 0 }' "$tsv")
    # ---- activity per sample
    local act_avg act_max conn_max
    read -r act_avg act_max conn_max < <(awk -F'\t' "$ACTIVE_FILTER"'
        { all[$1]++ } active() { a[$1]++ }
        END { for (s in all) { n++; t += a[s]; if (a[s] > m) m = a[s]; if (all[s] > c) c = all[s] }
              printf "%.1f %d %d\n", (n ? t / n : 0), m, c }' "$tsv")
    kv "Samples" "$samples processlist snapshots (one per second)"
    kv "Sessions" "up to $conn_max connected; active statements avg $act_avg, max $act_max (sleeping, system and pt-stalk sessions left out)"

    # ---- states, with what they mean
    echo
    printf '  %sWhat the active sessions were doing%s (sessions per snapshot: avg / max)\n' "$C_B" "$C_0"
    local st avg mx meaning
    while IFS=$'\t' read -r st avg mx; do
        meaning=$(state_meaning "$st")
        printf '    %-34s %6s / %-5s ' "${st:-(no state)}" "$avg" "$mx"
        if [[ -n $meaning ]]; then wrap 52 "$meaning"; else echo; fi
    done < <(awk -F'\t' -v ns="$samples" "$ACTIVE_FILTER"'
        active() { c[$8]++; per[$1 SUBSEP $8]++ }
        END {
            for (k in per) { split(k, p, SUBSEP); if (per[k] > m[p[2]]) m[p[2]] = per[k] }
            for (s in c) printf "%s\t%.1f\t%d\n", s, c[s] / ns, m[s]
        }' "$tsv" | sort -t$'\t' -k2,2nr | head -8)

    # ---- metadata / table lock waits, called out explicitly
    local mdl
    mdl=$(awk -F'\t' '$8 ~ /^Waiting for (table metadata lock|table level lock|global read lock|commit lock|table flush)$/ { n[$8]++; if ($7 > t[$8]) t[$8] = $7 }
        END { for (s in n) printf "%s: %d session-snapshots, longest %ss\n", s, n[s], t[s] }' "$tsv")
    echo
    if [[ -n $mdl ]]; then
        printf '  %sTable-level lock waits seen%s\n' "$C_R" "$C_0"
        printf '%s\n' "$mdl" | sed 's/^/    /'
        printf '    '; wrap 4 "Meaning: sessions could not even start using a table because another session held a table-level lock on it. Typical causes: an ALTER TABLE or other DDL waiting behind a long transaction, FLUSH TABLES WITH READ LOCK from a backup, or LOCK TABLES. Everything that touches that table queues behind it."
        finding_top "Table-level (metadata) lock waits in the processlist: $(printf '%s' "$mdl" | tr '\n' ';' | sed 's/;$//'). See the Sessions and queries section."
    else
        kv "Table-level locks" "no session was waiting for a metadata, table, global read or commit lock"
    fi

    # ---- long-running statements (one line per session, its longest time)
    echo
    printf '  %sLong-running statements%s (running %ss or longer; one entry per session, at its longest)\n' "$C_B" "$C_0" "$LONG_QUERY_SECS"
    local n_long=0 id user host db t state info
    awk -F'\t' -v min="$LONG_QUERY_SECS" "$ACTIVE_FILTER$AWK_FINGERPRINT"'
        active() && $7 + 0 >= min { if ($7 + 0 > best[$2]) { best[$2] = $7 + 0; row[$2] = $2 "\t" $3 "\t" $4 "\t" $5 "\t" $7 "\t" $8 "\t" $9; fp[$2] = fingerprint($9) } }
        END { for (i in row) print fp[i] "\t" row[i] }' "$tsv" | sort -t$'\t' -k6,6nr |
        awk -F'\t' '{ if (++shape[$1] <= 3 && shown < 12) { shown++; sub(/^[^\t]*\t/, ""); print } else hidden++ }
            END { if (hidden) printf "#more\t%d\n", hidden }' >"$WORK/long.tsv"
    while IFS=$'\t' read -r id user host db t state info; do
        [[ $id == "#more" ]] && continue
        n_long=$((n_long + 1))
        printf '    %s%5ss%s  id %s  %s@%s  db %s  state: %s\n' "$C_B" "$t" "$C_0" "$id" "$user" "$host" "$db" "${state:-none}"
        printf '           '; wrap 11 "${info:0:400}$( ((${#info} > 400)) && echo ' ...')"
    done <"$WORK/long.tsv"
    if grep -q '^#more' "$WORK/long.tsv"; then
        printf '    %s(%s more sessions ran the same statements; at most 3 per statement shape are listed)%s\n' "$C_D" "$(awk -F'\t' '/^#more/ {print $2}' "$WORK/long.tsv")" "$C_0"
    fi
    ((n_long)) || echo "    none"

    # ---- the same statement from many sessions: jobs and application patterns
    echo
    printf '  %sRepeated statements%s (literals replaced by ?; sessions = distinct connections running it)\n' "$C_B" "$C_0"
    printf '    %s%8s %10s %8s %6s  %s%s\n' "$C_B" sessions "max at once" "max time" hosts statement "$C_0"
    local sess conc tmax hosts fp
    while IFS=$'\t' read -r sess conc tmax hosts fp; do
        printf '    %8s %10s %7ss %6s  ' "$sess" "$conc" "$tmax" "$hosts"
        wrap 41 "${fp:0:220}"
    done < <(awk -F'\t' "$ACTIVE_FILTER$AWK_FINGERPRINT"'
        active() {
            f = fingerprint($9); key = f
            if (!((key, $2) in seen)) { seen[key, $2] = 1; s[key]++ }
            per[$1 SUBSEP key]++
            if ($7 + 0 > tm[key]) tm[key] = $7 + 0
            if (!((key, $4) in hseen)) { hseen[key, $4] = 1; h[key]++ }
        }
        END {
            for (k in per) { split(k, p, SUBSEP); if (per[k] > c[p[2]]) c[p[2]] = per[k] }
            for (k in s) printf "%d\t%d\t%d\t%d\t%s\n", s[k], c[k], tm[k], h[k], k
        }' "$tsv" | sort -t$'\t' -k2,2nr -k1,1nr | head -8)

    # ---- per table
    echo
    printf '  %sTables with the most active statements%s (from the SQL text)\n' "$C_B" "$C_0"
    printf '    %s%10s %8s  %-40s %s%s\n' "$C_B" "max at once" sessions table "statement types" "$C_0"
    awk -F'\t' "$ACTIVE_FILTER"'
        function addt(t, kind) {
            gsub(/`/, "", t); if (t !~ /\./ && $5 != "NULL" && $5 != "") t = $5 "." t
            k = t
            if (!((k, $1, $2) in dup)) { dup[k, $1, $2] = 1; per[$1 SUBSEP k]++ }
            if (!((k, $2) in ss)) { ss[k, $2] = 1; sess[k]++ }
            if (!((k, kind) in kd)) { kd[k, kind] = 1; kinds[k] = kinds[k] (kinds[k] ? "," : "") kind }
        }
        active() {
            # q is searched case-insensitively; o keeps the original case and is
            # cut at the same positions so the two stay aligned
            o = $9; q = tolower(o); kind = q; sub(/^[ (]*/, "", kind); sub(/[^a-z].*/, "", kind)
            while (match(q, /(update|into|from|join) +`?[a-z0-9_$]+`?(\.`?[a-z0-9_$]+`?)?/)) {
                m = substr(q, RSTART, RLENGTH); sub(/^[a-z]+ +/, "", m)
                if (m !~ /^(select|set|dual|lateral|\()/) addt(substr(o, RSTART + RLENGTH - length(m), length(m)), kind)
                q = substr(q, RSTART + RLENGTH); o = substr(o, RSTART + RLENGTH)
            }
        }
        END {
            for (k in per) { split(k, p, SUBSEP); if (per[k] > c[p[2]]) c[p[2]] = per[k] }
            for (k in sess) printf "%d\t%d\t%s\t%s\n", c[k], sess[k], k, kinds[k]
        }' "$tsv" | sort -t$'\t' -k1,1nr | head -8 | while IFS=$'\t' read -r conc sess tbl kinds; do
            printf '    %10s %8s  %-40s %s\n' "$conc" "$sess" "$tbl" "$kinds"
        done

    # ---- client hosts / users
    echo
    printf '  %sWho runs them%s (active statements per snapshot, max)\n' "$C_B" "$C_0"
    awk -F'\t' "$ACTIVE_FILTER"'
        active() { per[$1 SUBSEP $3 "@" $4]++ }
        END { for (k in per) { split(k, p, SUBSEP); if (per[k] > m[p[2]]) m[p[2]] = per[k] }
              for (u in m) printf "%d\t%s\n", m[u], u }' "$tsv" | sort -t$'\t' -k1,1nr | head -6 |
        while IFS=$'\t' read -r m u; do printf '    %5s  %s\n' "$m" "$u"; done

    if awk -F'\t' '$3 ~ /^mysql_router/ { f = 1 } END { exit !f }' "$tsv"; then
        printf '    '; wrap 4 "Note: MySQL Router accounts are connected (mysql_router*), so application connections arrive through Router and show the Router host, not the application server. Use the Router logs or performance_schema connection attributes to see the real clients."
    fi

    echo
    printf '  %sFiles%s  ' "$C_D" "$C_0"; wrap 9 "$(files_of processlist)"
}

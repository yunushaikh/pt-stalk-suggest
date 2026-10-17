# shellcheck shell=bash
# Observations that point to queries, the application or the OS rather than
# to a configuration value, plus caveats about the data itself.

rule_findings() {
    local x y

    x=$(sn Select_full_join win)
    is "$x >= 1" && finding "Joins without a usable index: Select_full_join $(human_num "$x")/s. Find them in the slow log / performance_schema digests (SUM_SELECT_FULL_JOIN)."

    x=$(sn Handler_read_rnd_next win); y=$(sn Select_scan win)
    is "$x >= 100000" && finding "Full table scans: Handler_read_rnd_next $(human_num "$x") rows/s, Select_scan $(human_num "$y")/s. Indexing these queries reduces buffer pool churn and CPU."

    x=$(sd Innodb_row_lock_waits)
    if is "$x > 0"; then
        y=$(calc "$(sd Innodb_row_lock_time) / $x")
        finding "Row lock waits: $(human_num "$x") during the capture, average $(human_num "$y") ms each; up to $(sn Innodb_row_lock_current_waits max) sessions waiting at once. See the lock-waits / transactions files of the capture."
    fi

    x=$(num "$(ib history_list)")
    is "$x > 1000000" && finding "InnoDB history list length reached $(human_num "$x"): purge is behind, usually because of a long-running transaction (see the transactions file). This slows reads and grows the undo tablespaces."

    x=$(num "$(ib semaphore_waits)")
    is "$x > 10" && finding "InnoDB semaphore waits: up to $x threads waiting in one status sample. See the SEMAPHORES section of innodbstatus for the hot latch."

    if [[ $MEM_SWAPPING -eq 1 ]]; then
        finding "The host swapped during the capture (swap-in avg $(h swap_in_avg) KiB/s, max $(h swap_in_max); swap-out avg $(h swap_out_avg) KiB/s; vm.swappiness = $(h swappiness)). mysqld pages being swapped in cause unpredictable stalls."
    fi

    x=$(sn Aborted_clients win)
    is "$x >= 1" && finding "Aborted_clients $(human_num "$x")/s: clients disconnect without closing (timeouts, killed app threads, max_allowed_packet). Check the error log with log_error_verbosity = 3."

    x=$(sn Threads_running max); y=$(num "$(h cpus)")
    is "$y > 0 && $x > 4 * $y" && finding "Threads_running peaked at $x on $y CPUs: a pile-up. Look at the processlist file at that second for the common state or query."

    x=$(num "$(h cpu_iowait_avg)")
    is "$x > 20" && finding "CPU iowait averaged $x% during the capture: the workload waits on storage."
}

data_caveats() {
    local up secs; up=$(num "$(h uptime)"); secs=$(num "$(h window_secs)")
    ((up < 86400)) && caveat "MySQL has been up only $(human_secs "$up"): counters since start do not represent normal load yet, and the buffer pool may still be warming up."
    ((secs < 20)) && caveat "Only $secs seconds of samples: rates in the window are noisy."
    ((${#SKIPPED_OTHER_SERVER[@]})) && caveat "Skipped captures of a different MySQL server; this report covers server $SERVER_ID only. Run the tool on each server's captures separately: ${SKIPPED_OTHER_SERVER[*]}"
    ((${#SKIPPED_CAPTURES[@]})) && caveat "Skipped captures from before a MySQL restart (counters reset): ${SKIPPED_CAPTURES[*]}"
    is "$(num "$(h mysqld_count)") > 1" && caveat "ps shows $(h mysqld_count) mysqld processes on this host: the memory budget assumes the largest one and counts the others as other processes."
    [[ -z $(h mem_total) || $(h mem_total) == 0 ]] && caveat "No meminfo in the capture: memory-based suggestions are not reliable."
    [[ $(h disk_how) == busiest ]] && caveat "Could not match datadir to an iostat device; disk numbers use the busiest device ($(h disk))."
    caveat "RAM comes from /proc/meminfo, which shows the host's memory even when mysqld runs in a container or pod with a lower memory limit; pt-stalk does not record cgroup limits, so memory suggestions assume the whole host is available."
    caveat "pt-stalk captures a short window, often during an incident. Window rates show that moment; settings should fit normal load with headroom for it, so compare with the 'since start' figures before changing anything."
}

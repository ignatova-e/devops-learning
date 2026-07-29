#!/usr/bin/env bash

read_cpu_counters() {
    awk '/^cpu / { idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print total, idle; exit }' /proc/stat
}

collect_values() {
    read -r cpu_total_before cpu_idle_before < <(read_cpu_counters)
    sleep 1
    read -r cpu_total_after cpu_idle_after < <(read_cpu_counters)

    cpu_usage_ratio=$(awk \
        -v total_before="$cpu_total_before" -v idle_before="$cpu_idle_before" \
        -v total_after="$cpu_total_after" -v idle_after="$cpu_idle_after" \
        'BEGIN {
            total_delta = total_after - total_before
            idle_delta = idle_after - idle_before
            if (total_delta > 0) printf "%.6f", (total_delta - idle_delta) / total_delta
            else print 0
        }')
    memory_total=$(awk '/^MemTotal:/ { print $2 * 1024; exit }' /proc/meminfo)
    memory_available=$(awk '/^MemAvailable:/ { print $2 * 1024; exit }' /proc/meminfo)
    read -r disk_total disk_available < <(df -B1 / | awk 'NR == 2 { print $2, $4 }')
}

create_metrics_file() {
    local output="${METRICS_FILE:-/var/www/custom-metrics/metrics}"
    local temporary_file
    mkdir -p "$(dirname "$output")"
    temporary_file=$(mktemp "${output}.XXXXXX")
    collect_values

    cat > "$temporary_file" <<EOF
# HELP custom_cpu_usage_ratio CPU busy fraction measured over one second.
# TYPE custom_cpu_usage_ratio gauge
custom_cpu_usage_ratio $cpu_usage_ratio
# HELP custom_memory_total_bytes Total RAM in bytes.
# TYPE custom_memory_total_bytes gauge
custom_memory_total_bytes $memory_total
# HELP custom_memory_available_bytes RAM available for new processes in bytes.
# TYPE custom_memory_available_bytes gauge
custom_memory_available_bytes $memory_available
# HELP custom_disk_size_bytes Size of the root filesystem in bytes.
# TYPE custom_disk_size_bytes gauge
custom_disk_size_bytes{mountpoint="/"} $disk_total
# HELP custom_disk_available_bytes Available space on the root filesystem in bytes.
# TYPE custom_disk_available_bytes gauge
custom_disk_available_bytes{mountpoint="/"} $disk_available
EOF
    chmod 0644 "$temporary_file"
    mv "$temporary_file" "$output"
}

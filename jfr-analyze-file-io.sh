#!/bin/bash
#
# analyze-file-io.sh - Extract and analyze File I/O events from JFR recordings
#
# Usage: ./analyze-file-io.sh [options] <recording.jfr>
#
# Arguments:
#   recording.jfr  - Path to the JFR recording file
#
# Options:
#   -p, --path <filter>       Filter results to paths containing this string
#   -s, --stack <filter>      Filter results to events with stack traces containing this string
#                             (e.g., "checksum", "MessageDigest", "DigestInputStream")
#   -h, --help                Show this help message
#
# Requirements:
#   - JDK 11+ with 'jfr' command in PATH
#   - awk (POSIX compatible)
#
# Examples:
#   ./analyze-file-io.sh myrecording.jfr
#   ./analyze-file-io.sh -p "/storage/" myrecording.jfr
#   ./analyze-file-io.sh --stack "checksum" myrecording.jfr
#   ./analyze-file-io.sh -p "/ThingworxStorage/" -s "MessageDigest" myrecording.jfr
#

set -e

# Colors for output (disable if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

# Parse command line arguments
show_help() {
    echo "Usage: $0 [options] <recording.jfr>"
    echo ""
    echo "Extracts File I/O events from a JFR recording and provides statistics"
    echo "on read/write operations, latencies, and block sizes."
    echo ""
    echo "Arguments:"
    echo "  recording.jfr             Path to the JFR recording file"
    echo ""
    echo "Options:"
    echo "  -p, --path <filter>       Filter to paths containing this string"
    echo "  -s, --stack <filter>      Filter to events with stack traces containing this string"
    echo "                            Useful for isolating specific operations like checksums"
    echo "                            (e.g., 'checksum', 'MessageDigest', 'DigestInputStream')"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 myrecording.jfr"
    echo "  $0 -p '/storage/' myrecording.jfr"
    echo "  $0 --stack 'checksum' myrecording.jfr"
    echo "  $0 -s 'MessageDigest' -p '/data/' myrecording.jfr"
    exit 0
}

JFR_FILE=""
PATH_FILTER=""
STACK_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -p|--path)
            PATH_FILTER="$2"
            shift 2
            ;;
        -s|--stack)
            STACK_FILTER="$2"
            shift 2
            ;;
        -*)
            # Check if this might be a file starting with dash
            if [ -f "$1" ]; then
                if [ -z "$JFR_FILE" ]; then
                    JFR_FILE="$1"
                else
                    echo -e "${RED}Error: Unexpected argument: $1${NC}"
                    echo "Use --help for usage information."
                    exit 1
                fi
            else
                echo -e "${RED}Error: Unknown option: $1${NC}"
                echo "Use --help for usage information."
                exit 1
            fi
            shift
            ;;
        *)
            if [ -z "$JFR_FILE" ]; then
                JFR_FILE="$1"
            else
                echo -e "${RED}Error: Unexpected argument: $1${NC}"
                echo "Use --help for usage information."
                exit 1
            fi
            shift
            ;;
    esac
done

# Check that JFR file was provided
if [ -z "$JFR_FILE" ]; then
    echo -e "${RED}Error: No JFR recording file specified.${NC}"
    echo "Use --help for usage information."
    exit 1
fi

# Verify file exists
if [ ! -f "$JFR_FILE" ]; then
    echo -e "${RED}Error: File not found: $JFR_FILE${NC}"
    exit 1
fi

# Verify jfr command is available
if ! command -v jfr &> /dev/null; then
    echo -e "${RED}Error: 'jfr' command not found. Ensure JDK 11+ is installed and in PATH.${NC}"
    exit 1
fi

# Create temporary files for processing
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

FILE_READ_JSON="$TEMP_DIR/file_read.json"
FILE_WRITE_JSON="$TEMP_DIR/file_write.json"

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}JFR File I/O Analysis${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo -e "Recording: ${BLUE}$JFR_FILE${NC}"
if [ -n "$PATH_FILTER" ]; then
    echo -e "Path filter: ${YELLOW}$PATH_FILTER${NC}"
fi
if [ -n "$STACK_FILTER" ]; then
    echo -e "Stack trace filter: ${YELLOW}$STACK_FILTER${NC}"
fi
echo ""

# Extract File Read events
echo -e "${BOLD}Extracting jdk.FileRead events...${NC}"
jfr print --events jdk.FileRead --json "$JFR_FILE" > "$FILE_READ_JSON" 2>/dev/null || true

# Extract File Write events
echo -e "${BOLD}Extracting jdk.FileWrite events...${NC}"
jfr print --events jdk.FileWrite --json "$JFR_FILE" > "$FILE_WRITE_JSON" 2>/dev/null || true

echo ""

# Function to analyze events from JSON
analyze_events() {
    local json_file="$1"
    local event_type="$2"
    local path_filter="$3"
    local bytes_field="$4"  # "bytesRead" or "bytesWritten"
    local stack_filter="$5" # Optional: filter by stack trace content

    # Check if file has content
    if [ ! -s "$json_file" ]; then
        echo -e "${YELLOW}No $event_type events found in recording.${NC}"
        return
    fi

    # Use awk to parse JSON and calculate statistics
    # This is a simplified parser that works with jfr's JSON output format
    awk -v event_type="$event_type" -v path_filter="$path_filter" -v bytes_field="$bytes_field" \
        -v stack_filter="$stack_filter" \
        -v RED="$RED" -v GREEN="$GREEN" -v YELLOW="$YELLOW" -v BLUE="$BLUE" -v BOLD="$BOLD" -v NC="$NC" '
    BEGIN {
        count = 0
        total_bytes = 0
        total_duration_ns = 0
        min_duration_ns = -1
        max_duration_ns = 0
        min_bytes = -1
        max_bytes = 0

        # For percentile calculation, store durations
        duration_count = 0

        # For path aggregation
        path_count = 0

        # Block size distribution buckets
        bucket_4k = 0
        bucket_8k = 0
        bucket_16k = 0
        bucket_32k = 0
        bucket_64k = 0
        bucket_128k = 0
        bucket_256k = 0
        bucket_512k = 0
        bucket_1m = 0
        bucket_larger = 0
    }

    # Parse duration from string like "PT0.016813081S" (ISO 8601) or "161.874 ms"
    # Compatible with BSD awk (macOS) - no capture groups in match()
    function parse_duration_ns(str,    num, unit) {
        # Handle ISO 8601 duration format: PT0.016813081S (seconds)
        if (match(str, /PT[0-9.]+S/)) {
            num = substr(str, RSTART + 2, RLENGTH - 3) + 0  # Skip "PT" and "S"
            return num * 1000000000  # Convert seconds to nanoseconds
        }

        gsub(/[^0-9. a-z]/, "", str)
        # Extract the numeric part
        if (match(str, /[0-9.]+/)) {
            num = substr(str, RSTART, RLENGTH) + 0
            # Get the rest after the number to find the unit
            unit = substr(str, RSTART + RLENGTH)
            gsub(/^ */, "", unit)  # trim leading spaces
            if (unit ~ /^ns/) {
                return num
            } else if (unit ~ /^us/) {
                return num * 1000
            } else if (unit ~ /^ms/) {
                return num * 1000000
            } else if (unit ~ /^s/) {
                return num * 1000000000
            }
            # No unit found, assume ms
            return num * 1000000
        }
        return 0
    }

    # Categorize block size
    function categorize_bytes(b) {
        if (b <= 4096) bucket_4k++
        else if (b <= 8192) bucket_8k++
        else if (b <= 16384) bucket_16k++
        else if (b <= 32768) bucket_32k++
        else if (b <= 65536) bucket_64k++
        else if (b <= 131072) bucket_128k++
        else if (b <= 262144) bucket_256k++
        else if (b <= 524288) bucket_512k++
        else if (b <= 1048576) bucket_1m++
        else bucket_larger++
    }

    # Format bytes for display
    function format_bytes(b) {
        if (b >= 1073741824) return sprintf("%.2f GiB", b / 1073741824)
        if (b >= 1048576) return sprintf("%.2f MiB", b / 1048576)
        if (b >= 1024) return sprintf("%.2f KiB", b / 1024)
        return sprintf("%d B", b)
    }

    # Format duration for display
    function format_duration(ns) {
        if (ns >= 1000000000) return sprintf("%.3f s", ns / 1000000000)
        if (ns >= 1000000) return sprintf("%.3f ms", ns / 1000000)
        if (ns >= 1000) return sprintf("%.3f us", ns / 1000)
        return sprintf("%.0f ns", ns)
    }

    # Process a complete event
    function process_event(    duration_ns, bytes) {
        # Apply path filter if specified
        path_matches = (path_filter == "" || index(current_path, path_filter) > 0)

        # Apply stack trace filter if specified
        stack_matches = (stack_filter == "" || index(current_stack_trace, stack_filter) > 0)

        if (path_matches && stack_matches) {
            duration_ns = parse_duration_ns(current_duration_str)
            bytes = current_bytes + 0

            if (duration_ns > 0 || bytes > 0) {
                count++
                total_bytes += bytes
                total_duration_ns += duration_ns

                if (min_duration_ns < 0 || duration_ns < min_duration_ns) min_duration_ns = duration_ns
                if (duration_ns > max_duration_ns) max_duration_ns = duration_ns

                if (min_bytes < 0 || bytes < min_bytes) min_bytes = bytes
                if (bytes > max_bytes) max_bytes = bytes

                # Store for percentile (limited to first 10000)
                if (duration_count < 10000) {
                    durations[duration_count] = duration_ns
                    duration_count++
                }

                # Categorize block size
                categorize_bytes(bytes)

                # Track per-path statistics
                path_ops[current_path]++
                path_bytes[current_path] += bytes
                path_duration[current_path] += duration_ns
            }
        }
    }

    # Capture duration (comes before path in JSON)
    /"duration"/ {
        # Extract duration - handle both string format and numeric format (BSD awk compatible)
        if (match($0, /"duration" *: *"[^"]*"/)) {
            current_duration_str = substr($0, RSTART, RLENGTH)
            gsub(/^"duration" *: *"/, "", current_duration_str)
            gsub(/"$/, "", current_duration_str)
        } else if (match($0, /"duration" *: *[0-9.]+/)) {
            current_duration_str = substr($0, RSTART, RLENGTH)
            gsub(/^"duration" *: */, "", current_duration_str)
            current_duration_str = current_duration_str " ns"
        }
    }

    # Capture path (comes after duration in JSON)
    /"path"/ {
        # Extract path value (BSD awk compatible)
        if (match($0, /"path" *: *"[^"]*"/)) {
            current_path = substr($0, RSTART, RLENGTH)
            # Remove the "path" : " prefix and trailing "
            gsub(/^"path" *: *"/, "", current_path)
            gsub(/"$/, "", current_path)
        }
    }

    # Capture bytes (comes last in JSON) - this triggers event processing
    /bytesRead|bytesWritten/ {
        # Extract bytes value (BSD awk compatible)
        if (match($0, /: *[0-9]+/)) {
            current_bytes = substr($0, RSTART, RLENGTH)
            gsub(/^: */, "", current_bytes)
            current_bytes = current_bytes + 0

            # Process event now that we have all fields
            if (current_path != "" && current_duration_str != "") {
                process_event()
            }
            # Reset for next event
            current_path = ""
            current_bytes = ""
            current_duration_str = ""
            current_stack_trace = ""
        }
    }

    # Capture stack trace content - accumulate all stack trace lines
    /"stackTrace"/ {
        in_stack_trace = 1
        current_stack_trace = ""
    }

    in_stack_trace {
        # Accumulate stack trace content
        current_stack_trace = current_stack_trace $0 "\n"

        # Detect end of stack trace (closing of stackTrace object)
        # Count braces to handle nested structures (BSD awk compatible)
        temp = $0
        gsub(/[^{]/, "", temp)
        stack_brace_count += length(temp)
        temp = $0
        gsub(/[^}]/, "", temp)
        stack_brace_count -= length(temp)

        if (stack_brace_count <= 0 && current_stack_trace != "") {
            in_stack_trace = 0
            stack_brace_count = 0
        }
    }

    # Also capture method names and class names from stack frames (BSD awk compatible)
    /"method"/ {
        if (match($0, /"method" *: *"[^"]*"/)) {
            method_val = substr($0, RSTART, RLENGTH)
            gsub(/^"method" *: *"/, "", method_val)
            gsub(/"$/, "", method_val)
            current_stack_trace = current_stack_trace " " method_val
        }
    }

    /"type"/ {
        if (match($0, /"type" *: *"[^"]*"/)) {
            type_val = substr($0, RSTART, RLENGTH)
            gsub(/^"type" *: *"/, "", type_val)
            gsub(/"$/, "", type_val)
            current_stack_trace = current_stack_trace " " type_val
        }
    }

    END {
        if (count == 0) {
            filter_msg = ""
            if (path_filter != "" && stack_filter != "") {
                filter_msg = " matching path \"" path_filter "\" and stack \"" stack_filter "\""
            } else if (path_filter != "") {
                filter_msg = " matching path \"" path_filter "\""
            } else if (stack_filter != "") {
                filter_msg = " matching stack \"" stack_filter "\""
            }
            print YELLOW "No " event_type " events found" filter_msg "." NC
            exit
        }

        # Sort durations for percentile calculation
        n = duration_count
        for (i = 0; i < n; i++) {
            for (j = i + 1; j < n; j++) {
                if (durations[i] > durations[j]) {
                    tmp = durations[i]
                    durations[i] = durations[j]
                    durations[j] = tmp
                }
            }
        }

        # Calculate percentiles
        p50_idx = int(n * 0.50)
        p90_idx = int(n * 0.90)
        p99_idx = int(n * 0.99)

        p50 = (n > 0) ? durations[p50_idx] : 0
        p90 = (n > 0) ? durations[p90_idx] : 0
        p99 = (n > 0) ? durations[p99_idx] : 0

        avg_duration_ns = (count > 0) ? total_duration_ns / count : 0
        avg_bytes = (count > 0) ? total_bytes / count : 0

        print BOLD "----------------------------------------" NC
        print BOLD event_type " Statistics" NC
        print BOLD "----------------------------------------" NC
        print ""

        print BOLD "Operation Count:" NC
        printf "  Total operations:     %s%d%s\n", YELLOW, count, NC
        print ""

        print BOLD "Data Volume:" NC
        printf "  Total data:           %s%s%s\n", BLUE, format_bytes(total_bytes), NC
        printf "  Average per op:       %s%s%s\n", BLUE, format_bytes(avg_bytes), NC
        printf "  Min block size:       %s\n", format_bytes(min_bytes)
        printf "  Max block size:       %s\n", format_bytes(max_bytes)
        print ""

        print BOLD "Latency Statistics:" NC
        printf "  Total I/O time:       %s%s%s\n", RED, format_duration(total_duration_ns), NC
        printf "  Average latency:      %s%s%s\n", YELLOW, format_duration(avg_duration_ns), NC
        printf "  Min latency:          %s\n", format_duration(min_duration_ns)
        printf "  Max latency:          %s%s%s\n", RED, format_duration(max_duration_ns), NC
        print ""

        print BOLD "Latency Percentiles:" NC
        printf "  P50 (median):         %s\n", format_duration(p50)
        printf "  P90:                  %s%s%s\n", YELLOW, format_duration(p90), NC
        printf "  P99:                  %s%s%s\n", RED, format_duration(p99), NC
        print ""

        print BOLD "Block Size Distribution:" NC
        total = bucket_4k + bucket_8k + bucket_16k + bucket_32k + bucket_64k + bucket_128k + bucket_256k + bucket_512k + bucket_1m + bucket_larger
        if (bucket_4k > 0) printf "  <= 4 KiB:    %6d  (%5.1f%%)\n", bucket_4k, (bucket_4k/total)*100
        if (bucket_8k > 0) printf "  <= 8 KiB:    %6d  (%5.1f%%)%s\n", bucket_8k, (bucket_8k/total)*100, (bucket_8k/total > 0.5) ? "  " RED "<-- Java default" NC : ""
        if (bucket_16k > 0) printf "  <= 16 KiB:   %6d  (%5.1f%%)\n", bucket_16k, (bucket_16k/total)*100
        if (bucket_32k > 0) printf "  <= 32 KiB:   %6d  (%5.1f%%)\n", bucket_32k, (bucket_32k/total)*100
        if (bucket_64k > 0) printf "  <= 64 KiB:   %6d  (%5.1f%%)%s\n", bucket_64k, (bucket_64k/total)*100, (bucket_64k/total > 0.3) ? "  " GREEN "<-- Good for network" NC : ""
        if (bucket_128k > 0) printf "  <= 128 KiB:  %6d  (%5.1f%%)\n", bucket_128k, (bucket_128k/total)*100
        if (bucket_256k > 0) printf "  <= 256 KiB:  %6d  (%5.1f%%)%s\n", bucket_256k, (bucket_256k/total)*100, (bucket_256k/total > 0.3) ? "  " GREEN "<-- Optimal for network" NC : ""
        if (bucket_512k > 0) printf "  <= 512 KiB:  %6d  (%5.1f%%)\n", bucket_512k, (bucket_512k/total)*100
        if (bucket_1m > 0) printf "  <= 1 MiB:    %6d  (%5.1f%%)\n", bucket_1m, (bucket_1m/total)*100
        if (bucket_larger > 0) printf "  > 1 MiB:     %6d  (%5.1f%%)\n", bucket_larger, (bucket_larger/total)*100
        print ""

        # Assessment
        print BOLD "Assessment:" NC
        if (avg_bytes <= 8192 && count > 10) {
            print RED "  WARNING: Small block sizes detected (avg " format_bytes(avg_bytes) ")" NC
            print RED "  This pattern is inefficient for network storage." NC
            print RED "  Consider increasing buffer size to 64-256 KiB." NC
        } else if (avg_bytes <= 32768 && count > 10) {
            print YELLOW "  NOTICE: Moderate block sizes detected (avg " format_bytes(avg_bytes) ")" NC
            print YELLOW "  Performance may improve with larger buffers (256 KiB)." NC
        } else {
            print GREEN "  OK: Block sizes appear reasonable (avg " format_bytes(avg_bytes) ")" NC
        }

        if (max_duration_ns > 100000000) {  # > 100ms
            print RED "  WARNING: High tail latency detected (max " format_duration(max_duration_ns) ")" NC
            print RED "  This may indicate network storage or contention issues." NC
        }
        print ""

        # Top paths by operation count
        print BOLD "Top Paths by Operation Count:" NC

        # Sort paths by count (simple bubble sort, limited output)
        path_list_count = 0
        for (p in path_ops) {
            path_list[path_list_count] = p
            path_list_count++
        }

        for (i = 0; i < path_list_count && i < 10; i++) {
            for (j = i + 1; j < path_list_count; j++) {
                if (path_ops[path_list[i]] < path_ops[path_list[j]]) {
                    tmp = path_list[i]
                    path_list[i] = path_list[j]
                    path_list[j] = tmp
                }
            }
        }

        for (i = 0; i < path_list_count && i < 5; i++) {
            p = path_list[i]
            avg_op_bytes = path_bytes[p] / path_ops[p]
            avg_op_dur = path_duration[p] / path_ops[p]
            printf "  %d. %s\n", i+1, p
            printf "     Ops: %d, Total: %s, Avg size: %s, Avg latency: %s\n",
                path_ops[p], format_bytes(path_bytes[p]), format_bytes(avg_op_bytes), format_duration(avg_op_dur)
        }
        print ""
    }
    ' "$json_file"
}

# Analyze File Read events
analyze_events "$FILE_READ_JSON" "File Read" "$PATH_FILTER" "bytesRead" "$STACK_FILTER"

# Analyze File Write events
analyze_events "$FILE_WRITE_JSON" "File Write" "$PATH_FILTER" "bytesWritten" "$STACK_FILTER"

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}Analysis Complete${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "Tips:"
echo "  - If most reads are <= 8 KiB, increase buffer size in Java code"
echo "  - High P99 latency on network storage suggests need for larger I/O sizes"
echo "  - Use -s/--stack to filter by stack trace (e.g., -s 'checksum' or -s 'MessageDigest')"
echo "  - Use 'jfr print --events jdk.FileRead $JFR_FILE' for raw event data"
echo ""

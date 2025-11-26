#!/bin/bash

DEBUG=true

#
# Example CSV input file containing chapter names and timings
# 
# 0:00:00,Introduction
# 0:01:22,DevOps Methodology
# 0:03:16,Interdependence & Shifting Left
# 0:05:12,Goals & Objectives
# 0:06:45,Topics Covered
# 0:08:47,ThingWorx Dockerfiles
# 0:11:20,Container Image Import/Load
# 0:15:29,Enhanced Docker Compose
# 0:31:03,Trial License vs. License File
# 0:35:31,Environment File & Defaults
# 0:38:29,Resource Allocation & Sizing
# 0:55:38,Diagnostic & Monitoring Instrumentation
# 1:11:40,Templatized Configuration Files
# 1:22:57,Logging Configuration & Purging
# 1:29:12,Configuration Tweaks (variables vs. files)
# 1:41:14,Platform Settings Validation
# 1:56:05,Container Runtime Debugging
# 

debug_echo() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $1" >&2
    fi
}

recordings="../recordings"
csvfile="$recordings/chapters.csv"
outfile="$recordings/chapters.ffmetadata"
video_in_file="$recordings/Mastering\ ThingWorx\ Container\ Runtime.mp4"
video_out_file="$recordings/Mastering\ ThingWorx\ Container\ Runtime\ -\ chapters.mp4"

debug_echo "Starting creation of metadata file '$outfile' from '$csvfile'"

echo ";FFMETADATA1" > "$outfile"
debug_echo "Wrote metadata header to '$outfile'"

convert_hhmmss_to_ms() {
    local hh mm ss
    IFS=: read -r hh mm ss <<< "$1"
    if [[ ! "$hh" =~ ^[0-9]+$ || ! "$mm" =~ ^[0-9]+$ || ! "$ss" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Invalid timestamp format '$1', expected hh:mm:ss" >&2
        exit 1
    fi
    local ms=$((10#$hh * 3600000 + 10#$mm * 60000 + 10#$ss * 1000))
    debug_echo "Converted timestamp '$1' to milliseconds: $ms"
    echo "$ms"
}

starts=()
titles=()

# Read CSV line by line, trimming whitespace, with debug messages to stderr
while IFS=',' read -r time title || [[ -n "$time" ]]; do
    # Trim leading/trailing whitespace on time and title
    time="${time#"${time%%[![:space:]]*}"}"
    time="${time%"${time##*[![:space:]]}"}"
    title="${title#"${title%%[![:space:]]*}"}"
    title="${title%"${title##*[![:space:]]}"}"
    
    debug_echo "Read CSV line: time='$time', title='$title'"

    ms=$(convert_hhmmss_to_ms "$time")
    starts+=("$ms")
    titles+=("$title")

    debug_echo "Appended to arrays: start=$ms, title='$title'"
    debug_echo "Current array sizes: starts=${#starts[@]}, titles=${#titles[@]}"
done < "$csvfile"

debug_echo "Total chapters read: ${#starts[@]}"

for (( i=0; i < ${#starts[@]}; i++ )); do
    start=${starts[i]}
    if (( i < ${#starts[@]} - 1 )); then
        end=$((${starts[i+1]} - 1))
    else
        end=99999999  # Placeholder large end for last chapter
    fi

    debug_echo "Writing chapter $((i+1)): START=$start END=$end TITLE='${titles[i]}'"

    cat <<EOF >> "$outfile"

[CHAPTER]
TIMEBASE=1/1000
START=$start
END=$end
title=${titles[i]}
EOF
done

debug_echo "Metadata file '$outfile' created successfully with ${#starts[@]} chapters."
echo "Done. Add chapters to your mp4 with ffmpeg:"
echo "ffmpeg -i $video_in_file -i $outfile -map_metadata 1 -codec copy $video_out_file"

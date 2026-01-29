#!/bin/sh

# Tomcat 9 to 11 upgrade date/time - duration units changed from ms to us (microseconds)
UPGRADE_DATE="2026-01-17"
UPGRADE_TIME="23:00"  # HH:MM format

cd "./2026-01-29/accessLogs"

# Convert to numeric format for comparison
upgrade_num=$(echo "$UPGRADE_DATE" | tr -d '-')
cutoff="${upgrade_num}$(echo "$UPGRADE_TIME" | tr -d ':')"

for file in *.txt; do
  date_part=$(echo "$file" | grep -oE '2026-01-[0-9]{2}')
  date_num=$(echo "$date_part" | tr -d '-')
  
  # Skip only if we can confirm the file is before upgrade date
  if [ -n "$date_num" ] && [ "$date_num" -lt "$upgrade_num" ]; then
    continue
  fi
  
  echo "Processing: $file"
  awk -v cutoff="$cutoff" '
    BEGIN {
      months["Jan"]=1; months["Feb"]=2; months["Mar"]=3; months["Apr"]=4
      months["May"]=5; months["Jun"]=6; months["Jul"]=7; months["Aug"]=8
      months["Sep"]=9; months["Oct"]=10; months["Nov"]=11; months["Dec"]=12
    }
    {
      # Parse timestamp from field 4: [17/Jan/2026:22:30:05
      ts = substr($4, 2)
      split(ts, parts, ":")
      split(parts[1], dparts, "/")
      
      day = dparts[1]
      mon = months[dparts[2]]
      year = dparts[3]
      hour = parts[2]
      min = parts[3]
      
      datetime = sprintf("%04d%02d%02d%02d%02d", year, mon, day, hour, min)
      
      # Only convert if on/after cutoff AND not already converted (no decimal)
      if (datetime >= cutoff && index($11, ".") == 0) {
        $11 = $11/1000
      }
    }
    1' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
done
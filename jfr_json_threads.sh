
#!/usr/bin/env bash
# Convert JFR ThreadStart/ThreadEnd (JSON) to CSV or Tomcat access log with high-precision durations.
#
# Expected JFR command (pipe into this script):
#   jfr print --events jdk.ThreadStart,jdk.ThreadEnd --json --stack-depth 0 run.jfr \
#     | ./jfr_json_threads.sh --format=csv    > thread_start_statistics.csv
#   jfr print --events jdk.ThreadStart,jdk.ThreadEnd --json --stack-depth 0 run.jfr \
#     | ./jfr_json_threads.sh --format=tomcat > thread_start_statistics.log
#
# Notes:
# - CSV columns: start_time,end_time,duration_ms,thread_group,thread_name,parent_thread_group,parent_thread_name
# - Tomcat (ECLF-like): - - - [end_ts] "parent_thread_group -> thread_group" 200 - <duration_ms> <thread_name>
# - Timestamps are emitted EXACTLY as read (no TZ normalization). Duration is milliseconds (float), full fractional precision.
# - Matching by javaThreadId; starts/ends are paired FIFO per id.
#
# Dependency: jq >= 1.6 (we do our own fractional parsing; no mktime or fromdateiso8601 in awk).

set -euo pipefail
export LC_ALL=C

FORMAT="csv"
if [[ $# -gt 0 ]]; then
  case "${1:-}" in
    --format=csv)    FORMAT="csv" ;;
    --format=tomcat) FORMAT="tomcat" ;;
    *) echo "Usage: $0 [--format=csv|tomcat]" >&2; exit 2 ;;
  esac
fi

# Stream events as TSV: type, startTime, thread.javaName, thread.javaThreadId, parentThread.javaName
jq -r '
  (.recording.events // .events // .)[]
  | select(.type=="jdk.ThreadStart" or .type=="jdk.ThreadEnd")
  | [
      .type,
      .values.startTime,
      .values.thread.javaName,
      (.values.thread.javaThreadId|tostring),
      (.values.parentThread?.javaName // "")
    ]
  | @tsv
' | awk -F '\t' -v OFS=',' -v FORMAT="$FORMAT" '
# ---------------------------
# AWK helpers: fast ISO8601 → ms (portable, no mktime)
# ---------------------------
function days_since_epoch(Y,M,D,  a,y1,m1,JDN){
  a=int((14-M)/12); y1=Y+4800-a; m1=M+12*a-3
  JDN = D + int((153*m1 + 2)/5) + 365*y1 + int(y1/4) - int(y1/100) + int(y1/400) - 32045
  return JDN - 2440588
}
# Parse "YYYY-MM-DDTHH:MM:SS.fracZ" → total milliseconds since epoch (float)
function iso_to_ms(iso,   date,time,Y,M,D,h,mi,s,sec,frac,dotpos,days,parts){
  split(iso, parts, "T"); date=parts[1]; time=parts[2]
  gsub(/Z$/, "", time)

  split(date, d, "-"); Y=d[1]+0; M=d[2]+0; D=d[3]+0
  split(time, t, ":"); h=t[1]+0; mi=t[2]+0; s=t[3]
  sec=s; frac=""
  dotpos = index(s, ".")
  if (dotpos>0) { sec=substr(s,1,dotpos-1)+0; frac=substr(s,dotpos+1) } else { sec=s+0 }
  # fractional ms = 1000 * ("0." + frac) (handles 3/6/9 digits)
  frac_ms = (frac=="" ? 0.0 : ("0." frac) * 1000.0)

  days = days_since_epoch(Y,M,D)
  return days*86400000.0 + h*3600000.0 + mi*60000.0 + sec*1000.0 + frac_ms
}

# Strip all digits (0-9) to form thread_group variants
function strip_digits(s){ gsub(/[0-9]/, "", s); return s }

# Convert ISO8601 end_time to Tomcat CLF timestamp: [dd/MMM/yyyy:HH:MM:SS +0000]
function iso_to_clf(iso,   date,time,Y,M,D,h,mi,s,sec,dotpos,months,mm){
  split(iso, a, "T"); date=a[1]; time=a[2]
  gsub(/Z$/, "", time)

  split(date, d, "-"); Y=d[1]; M=d[2]+0; D=d[3]
  split(time, t, ":"); h=t[1]; mi=t[2]; s=t[3]
  dotpos = index(s, "."); if (dotpos>0) s = substr(s,1,dotpos-1)

  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", months, " ")
  mm = months[M]
  return "[" D "/" mm "/" Y ":" h ":" mi ":" s " +0000]"
}

# Normalize thread_name:
# Move any digit group of length >=4 that is not already at the end to the end, prefixed by a single "-".
# e.g., "pool-456112-thread-1" -> "pool--thread-1-456112"
function normalize_thread_name(s,   i,ch,out,moved,j,len,group,endpos){
  out=""; moved=""
  len=length(s); i=1
  while (i<=len) {
    ch=substr(s,i,1)
    if (ch>="0" && ch<="9") {
      j=i
      while (j<=len) {
        c=substr(s,j,1)
        if (c>="0" && c<="9") j++
        else break
      }
      group=substr(s,i,j-i)
      endpos = i + (j-i) - 1
      if (length(group)>=4) {
        if (endpos==len) {
          # digits already at end: keep in place
          out = out group
        } else {
          # move this group to the end
          moved = (moved=="" ? group : moved "-" group)
        }
      } else {
        # keep short digit groups (<=3)
        out = out group
      }
      i=j
    } else {
      out = out ch
      i++
    }
  }
  if (moved!="") out = out "-" moved
  return out
}

BEGIN{
  if (FORMAT=="csv") {
    # Order: start_time,end_time,duration_ms,thread_group,thread_name,parent_thread_group,parent_thread_name
    print "start_time","end_time","duration_ms","thread_group","thread_name","parent_thread_group","parent_thread_name"
  }
}

# Maintain FIFO queues per javaThreadId using head/tail indices
function enqueue(id, s_time, t_name, p_name,   idx){
  q_tail[id]++
  idx = q_tail[id]
  st_time[id,idx] = s_time
  th_name[id,idx] = t_name
  pt_name[id,idx] = p_name
  if (!(id in q_head)) q_head[id]=1
}
function has_item(id){ return (id in q_head) && (q_head[id] <= q_tail[id]) }
function dequeue(id,   idx, s_time, t_name, p_name){
  idx = q_head[id]
  s_time = st_time[id,idx]
  t_name = th_name[id,idx]
  p_name = pt_name[id,idx]
  delete st_time[id,idx]; delete th_name[id,idx]; delete pt_name[id,idx]
  q_head[id]++
  if (q_head[id] > q_tail[id]) { delete q_head[id]; delete q_tail[id] }
  return s_time SUBSEP t_name SUBSEP p_name
}

# ---------------------------
# Streamed event handling
# ---------------------------
{
  typ   = $1
  ts    = $2       # startTime (for Start or End; for End = end_time)
  tname = $3       # thread.javaName
  tid   = $4       # thread.javaThreadId (string)
  pname = $5       # parentThread.javaName (maybe empty)

  if (typ=="jdk.ThreadStart") {
    enqueue(tid, ts, tname, pname)
  }
  else if (typ=="jdk.ThreadEnd") {
    if (has_item(tid)) {
      data = dequeue(tid)
      split(data, arr, SUBSEP)
      s_ts   = arr[1]
      s_name = arr[2]
      p_name_start = arr[3]  # parent at start

      dur = iso_to_ms(ts) - iso_to_ms(s_ts)

      # Compute groups and normalized name
      tg   = strip_digits(s_name)
      ptg  = strip_digits(p_name_start)
      tn_out = normalize_thread_name(s_name)

      if (FORMAT=="csv") {
        print s_ts, ts, dur, tg, tn_out, ptg, p_name_start
      } else {
        # Tomcat access log: include thread_name after duration_ms
        # - - - [end_ts] "parent_thread_group -> thread_group" 200 - <duration_ms> <thread_name>
        clf_ts = iso_to_clf(ts)
        req    = ptg " -> " tg
        printf("- - - %s \"%s\" 200 - %.6f %s\n", clf_ts, req, dur, tn_out)
      }
    }
    # else: unmatched end; ignore
  }
}
'


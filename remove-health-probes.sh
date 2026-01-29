#!/bin/sh

# Remove health check probe lines (/health, /ready, /healthz) from access logs

# Pattern to match health probe requests
MATCH_PATTERN='/\/health|\/ready|\/healthz/'

if [ -z "$1" ]; then
  echo "Usage: $0 <file-glob-pattern>"
  echo "Example: $0 './2026-01-29/accessLogs/*.txt'"
  exit 1
fi

FILE_PATTERN="$1"

echo "Sample of lines to be removed (first 15 matches):"
echo "================================================="
sed -n -E "${MATCH_PATTERN}p" $FILE_PATTERN | head -15
echo "================================================="
echo ""

printf "Do you want to remove these lines from the files? [y/N]: "
read answer

case "$answer" in
  [yY])
    echo "Removing lines..."
    sed -i '' -E "${MATCH_PATTERN}d" $FILE_PATTERN
    echo "Done."
    ;;
  *)
    echo "Aborted."
    ;;
esac

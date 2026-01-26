#!/bin/bash

delimiter=","
keep_seconds=false

# Parse command line options
while getopts "d:s" opt; do
  case $opt in
    d) delimiter="$OPTARG" ;;
    s) keep_seconds=true ;;
    \?) echo "Invalid option -$OPTARG" >&2 ;;
  esac
done

# Initialize a flag to track the header
header_printed=false
line_counter=2  # Start from 2 because the header is line 1

# Loop through all files matching the pattern
for file in Entity*Statistics-*.csv; do
  # Extract the datetime part from the filename
  datetime=$(echo "$file" | sed -n 's/.*-\([0-9]\{14\}\)-.*/\1/p')

  # Extract the host system part from the filename
  host_system=$(echo "$file" | sed -n 's/.*-\([0-9]\{14\}\)-\([a-zA-Z0-9]*\)\.csv/\2/p')

  # Convert the datetime to a standard format using awk and printf
  if $keep_seconds; then
    formatted_datetime=$(echo "$datetime" | awk '{printf "%s-%s-%s %s:%s:%s\n", substr($0, 1, 4), substr($0, 5, 2), substr($0, 7, 2), substr($0, 9, 2), substr($0, 11, 2), substr($0, 13, 2)}')
  else
    formatted_datetime=$(echo "$datetime" | awk '{printf "%s-%s-%s %s:%s\n", substr($0, 1, 4), substr($0, 5, 2), substr($0, 7, 2), substr($0, 9, 2), substr($0, 11, 2)}')
  fi

  # Read the file and prepend the formatted datetime and host system to each line
  while IFS= read -r line; do
    if [ "$header_printed" = false ]; then
      # Print the header with the new timestamp field, name, type, impact, executionTimeSec, meanTimeSec, and meanTimeMin columns
      echo "timestamp${delimiter}host_system${delimiter}statisticName${delimiter}name${delimiter}type${delimiter}minTime${delimiter}maxTime${delimiter}meanTime${delimiter}count${delimiter}impact${delimiter}executionTimeSec${delimiter}meanTimeSec${delimiter}meanTimeMin${delimiter}maxTimeSec"
      header_printed=true
    fi

    # Skip the original header line
    if [ "$line" != "statisticName,minTime,maxTime,meanTime,count" ]; then
      # Replace commas with the specified delimiter and periods with commas if delimiter is ;
      if [ "$delimiter" = ";" ]; then
        line=$(echo "$line" | sed -E 's/,/;/g; s/([0-9])\.([0-9])/\1,\2/g')
      fi

      # Split the line into its components
      IFS="," read -r statisticName minTime maxTime meanTime count <<< "$line"

      # Directly write the formulas with escaped quotes using structured references
      name_formula="\"=TRIM(MID([@statisticName]${delimiter} FIND(\"\"¤\"\"${delimiter} SUBSTITUTE([@statisticName]${delimiter} \"\".\"\"${delimiter} \"\"¤\"\"${delimiter} 4)) + 1${delimiter} LEN([@statisticName])))\""
      type_formula="\"=MID([@statisticName]${delimiter} FIND(\"\"#\"\"${delimiter} SUBSTITUTE([@statisticName]${delimiter} \"\".\"\"${delimiter} \"\"#\"\"${delimiter} 4)) + 1${delimiter} FIND(\"\"#\"\"${delimiter} SUBSTITUTE([@statisticName]${delimiter} \"\".\"\"${delimiter} \"\"#\"\"${delimiter} 5)) - FIND(\"\"#\"\"${delimiter} SUBSTITUTE([@statisticName]${delimiter} \"\".\"\"${delimiter} \"\"#\"\"${delimiter} 4)) - 1)\""
      impact_formula="\"=LOG(([@meanTimeSec]^0,4) * [@count])\""
      executionTimeSec_formula="\"=[@meanTime]*[@count]/1000\""
      meanTimeSec_formula="\"=[@meanTime]/1000\""
      meanTimeMin_formula="\"=[@meanTimeSec]/60\""
      maxTimeSec_formula="\"=[@maxTime]/1000\""
      
      # Print the line with the new name, type, impact, executionTimeSec, meanTimeSec, meanTimeMin, and maxTimeSec columns
      echo "$formatted_datetime${delimiter}$host_system${delimiter}$statisticName${delimiter}$name_formula${delimiter}$type_formula${delimiter}$minTime${delimiter}$maxTime${delimiter}$meanTime${delimiter}$count${delimiter}$impact_formula${delimiter}$executionTimeSec_formula${delimiter}$meanTimeSec_formula${delimiter}$meanTimeMin_formula${delimiter}$maxTimeSec_formula"
      line_counter=$((line_counter + 1))
    fi
  done < "$file"
done

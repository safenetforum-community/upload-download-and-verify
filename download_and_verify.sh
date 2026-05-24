#!/bin/bash

# Script to download files using ant file download and verify MD5 checksums

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

# Parallel jobs config (env var or -j flag, default 4)
PARALLEL_JOBS="${PARALLEL_JOBS:-1}"
while [ $# -gt 0 ]; do
    case "$1" in
        -j|--jobs)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-j N|--jobs N]"
            echo "  -j, --jobs N    Number of parallel downloads (default: 4)"
            echo "Env: PARALLEL_JOBS=N"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [-j N|--jobs N]" >&2
            exit 1
            ;;
    esac
done

if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [ "$PARALLEL_JOBS" -lt 1 ]; then
    echo "Error: PARALLEL_JOBS must be a positive integer (got: $PARALLEL_JOBS)" >&2
    exit 1
fi

# Per-run working directory for downloads and worker results
RESULTS_DIR=$(mktemp -d "$(pwd)/.ant-download-XXXXXX")
trap 'rm -rf "$RESULTS_DIR"' EXIT

# Persistent per-run directory for per-download ant logs (kept after exit)
LOG_DIR="$(pwd)/download-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

# Array to store download information
declare -a downloads

# Function to parse and add download command
add_download() {
    local cmd="$1"
    
    # Extract hash (64 character hex string after "ant file download")
    # Supports both old format (--retries N <hash>) and new format (<hash> -o)
    local hash=$(echo "$cmd" | grep -oP 'ant file download\s+(--retries\s+[0-9]+\s+)?\K[a-f0-9]{64}')
    
    # Extract expected MD5 (32 character hex string after md5sum)
    # New format: # <duration> md5sum <md5> or old format: #md5sum <md5>
    local expected_md5=$(echo "$cmd" | grep -oP 'md5sum[[:space:]]+\K[a-f0-9]{32}')
    
    if [ -z "$hash" ] || [ -z "$expected_md5" ]; then
        echo "Warning: Could not parse hash or MD5 from: $cmd" >&2
        return
    fi
    
    # Extract filename - supports both old and new format
    # New format: ant file download <hash> -o <filename>  # ...
    # Old format: ant file download --retries 20 <hash> <filename>  # ...
    local filename=""

    # Try new format first: -o <filename>
    filename=$(echo "$cmd" | grep -oP -- '-o\s+\K[^\s#]+')

    # Fall back to old format: hash followed by filename before #
    if [ -z "$filename" ]; then
        local after_hash=$(echo "$cmd" | sed "s/.*$hash[[:space:]]*//")
        filename=$(echo "$after_hash" | sed 's/#.*//' | xargs)
    fi
    
    # If filename is just "." or empty, try to extract from after the MD5 in the comment
    if [ "$filename" = "." ] || [ -z "$filename" ]; then
        # Extract filename from after the MD5 hash in the comment
        # Pattern: md5sum <md5> <filename> <size>
        filename=$(echo "$cmd" | sed -n "s/.*md5sum[[:space:]]*$expected_md5[[:space:]]*\([^[:space:]]*\).*/\1/p" | head -1)
        
        # If still empty, try to get quoted filename
        if [ -z "$filename" ]; then
            filename=$(echo "$cmd" | grep -oP "'[^']+'" | head -1 | tr -d "'")
        fi
        
        # If still empty, use hash as fallback
        if [ -z "$filename" ]; then
            filename="${hash:0:16}.bin"
        fi
    fi
    
    # Remove quotes from filename if present
    filename=$(echo "$filename" | sed "s/^['\"]//;s/['\"]$//")
    
    # Extract upload date (last field, format: dd/mm/yy)
    # Pattern: date is at the end after the cost
    local upload_date=$(echo "$cmd" | grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{2}$' || echo "")
    
    downloads+=("$hash|$filename|$expected_md5|$upload_date")
}

# Load download commands from uploads.txt file
UPLOADS_FILE="uploads.txt"

if [ ! -f "$UPLOADS_FILE" ]; then
    echo "Error: $UPLOADS_FILE not found!"
    echo "Please make sure uploads.txt exists in the current directory."
    exit 1
fi

# Parse all commands from uploads.txt
echo "Loading download commands from $UPLOADS_FILE..."
while IFS= read -r line; do
    # Skip empty lines and lines starting with #
    if [ -n "$line" ] && ! [[ "$line" =~ ^[[:space:]]*# ]]; then
        add_download "$line"
    fi
done < "$UPLOADS_FILE"

total=${#downloads[@]}
echo "Found $total files to download and verify"
echo ""

# Capture script start time
script_start_time=$(date '+%Y-%m-%d %H:%M:%S')
script_start_epoch=$(date +%s)

# Capture ant client version
if command -v ant >/dev/null 2>&1; then
    ant_version=$(ant --version 2>/dev/null | head -1 | tr -d '\r')
    [ -z "$ant_version" ] && ant_version="unknown"
else
    ant_version="ant CLI not found"
fi

# Arrays to store results for summary
declare -a result_filenames
declare -a result_actual_md5
declare -a result_expected_md5
declare -a result_verified
declare -a result_download_time
declare -a result_file_size
declare -a result_upload_date

# Flag to track if script was interrupted
interrupted=0

# Function to format time (same format as upload.sh: HHh MMm SSs with zero-padding)
format_time() {
    local seconds=$1
    # Convert duration to hours, minutes, and seconds
    local hours=$((seconds / 3600))
    local mins=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    # Format duration string with zero-padding (always show hours and minutes)
    printf "%02dh %02dm %02ds" $hours $mins $secs
}

# Function to calculate years and days since upload date
# Input: upload_date in format dd/mm/yy
# Output: formatted string like "0y 5d" or "2y 10d"
calculate_age() {
    local upload_date="$1"
    
    if [ -z "$upload_date" ] || [ "$upload_date" = "N/A" ]; then
        echo "N/A"
        return
    fi
    
    # Parse date: dd/mm/yy
    local day=$(echo "$upload_date" | cut -d'/' -f1)
    local month=$(echo "$upload_date" | cut -d'/' -f2)
    local year=$(echo "$upload_date" | cut -d'/' -f3)
    
    # Convert 2-digit year to 4-digit (assuming 20xx for years 00-99)
    if [ ${#year} -eq 2 ]; then
        if [ "$year" -lt 50 ]; then
            year="20$year"
        else
            year="19$year"
        fi
    fi
    
    # Get current date
    local current_date=$(date +%Y-%m-%d)
    local upload_date_formatted="${year}-${month}-${day}"
    
    # Calculate difference in days using date command
    if date -d "$upload_date_formatted" >/dev/null 2>&1; then
        # Linux date command
        local upload_epoch=$(date -d "$upload_date_formatted" +%s)
        local current_epoch=$(date -d "$current_date" +%s)
    elif date -j -f "%Y-%m-%d" "$upload_date_formatted" >/dev/null 2>&1; then
        # macOS date command
        local upload_epoch=$(date -j -f "%Y-%m-%d" "$upload_date_formatted" +%s)
        local current_epoch=$(date -j -f "%Y-%m-%d" "$current_date" +%s)
    else
        echo "N/A"
        return
    fi
    
    local diff_seconds=$((current_epoch - upload_epoch))
    
    if [ $diff_seconds -lt 0 ]; then
        echo "N/A"
        return
    fi
    
    local diff_days=$((diff_seconds / 86400))
    local years=$((diff_days / 365))
    local days=$((diff_days % 365))
    
    printf "%dy %dd" $years $days
}

# Function to format file size in GB/MB/KB with one decimal place
format_size() {
    local size_bytes=$1
    local size_gb size_mb size_kb
    
    if [ "$size_bytes" = "N/A" ] || [ "$size_bytes" = "Failed Download" ]; then
        echo "$size_bytes"
        return
    fi
    
    # Convert to GB, MB, or KB with one decimal place
    if command -v bc >/dev/null 2>&1; then
        size_gb=$(echo "scale=1; $size_bytes / 1073741824" | bc)
        size_mb=$(echo "scale=1; $size_bytes / 1048576" | bc)
        size_kb=$(echo "scale=1; $size_bytes / 1024" | bc)
        
        # Choose appropriate unit (GB if >= 1GB, MB if >= 1MB, otherwise KB)
        if (( $(echo "$size_gb >= 1" | bc -l 2>/dev/null || echo "0") )); then
            printf "%.1f GB" "$size_gb"
        elif (( $(echo "$size_mb >= 1" | bc -l 2>/dev/null || echo "0") )); then
            printf "%.1f MB" "$size_mb"
        else
            printf "%.1f KB" "$size_kb"
        fi
    elif command -v awk >/dev/null 2>&1; then
        size_gb=$(awk "BEGIN {printf \"%.1f\", $size_bytes / 1073741824}")
        size_mb=$(awk "BEGIN {printf \"%.1f\", $size_bytes / 1048576}")
        size_kb=$(awk "BEGIN {printf \"%.1f\", $size_bytes / 1024}")
        
        # Choose appropriate unit
        if (( $(awk "BEGIN {print ($size_gb >= 1)}") )); then
            printf "%.1f GB" "$size_gb"
        elif (( $(awk "BEGIN {print ($size_mb >= 1)}") )); then
            printf "%.1f MB" "$size_mb"
        else
            printf "%.1f KB" "$size_kb"
        fi
    else
        # Fallback: simple division and comparison
        size_gb=$((size_bytes / 1073741824))
        size_mb=$((size_bytes / 1048576))
        size_kb=$((size_bytes / 1024))
        
        if [ $size_gb -ge 1 ]; then
            printf "%d GB" "$size_gb"
        elif [ $size_mb -ge 1 ]; then
            printf "%d MB" "$size_mb"
        else
            printf "%d KB" "$size_kb"
        fi
    fi
}

# Function to print summary
print_summary() {
    local is_interrupted=$1
    local completed_count=${#result_filenames[@]}
    # Log file is written to the current working directory (where the command was run)
    local log_file="$(pwd)/log_download_and_verify.txt"
    
    # Function to output to both terminal and file
    output_both() {
        echo "$1" | tee -a "$log_file"
    }
    
    # Function to output printf to both terminal and file
    printf_both() {
        printf "$@" | tee -a "$log_file"
    }
    
    # Add blank lines to log file for readability
    echo "" >> "$log_file"
    echo "" >> "$log_file"
    
    if [ $is_interrupted -eq 1 ]; then
        echo ""
        echo -e "${RED}⚠ Script interrupted by user (Ctrl+C)${RESET}" | tee -a "$log_file"
        output_both "Printing results for $completed_count completed file(s)..."
        echo ""
    fi
    
    if [ $completed_count -eq 0 ]; then
        output_both "No files have been processed yet."
        return
    fi
    
    output_both "=========================================="
    output_both "Summary:"
    output_both "  Script started: $script_start_time"
    output_both "  ant client:     $ant_version"
    output_both "  Parallel downloads: $PARALLEL_JOBS"
    output_both "  Log directory:  $LOG_DIR"
    output_both ""
    
    # Print detailed summary for each file
    # Header row - right-align Size, Time, and Age to match data
    printf_both "%-50s %-32s %-32s %-6s %12s %12s %10s\n" "Filename" "Actual MD5" "Expected MD5" "Status" "Size" "Time" "Age"
    # Separator row
    printf_both "%-50s %-32s %-32s %-6s %12s %12s %10s\n" "$(printf '%.0s─' {1..50})" "$(printf '%.0s─' {1..32})" "$(printf '%.0s─' {1..32})" "$(printf '%.0s─' {1..6})" "$(printf '%.0s─' {1..12})" "$(printf '%.0s─' {1..12})" "$(printf '%.0s─' {1..10})"
    
    for i in "${!result_filenames[@]}"; do
        filename="${result_filenames[$i]}"
        actual_md5="${result_actual_md5[$i]}"
        expected_md5="${result_expected_md5[$i]}"
        verified="${result_verified[$i]}"
        download_time="${result_download_time[$i]}"
        file_size="${result_file_size[$i]}"
        upload_date="${result_upload_date[$i]}"
        time_formatted=$(format_time $download_time)
        age_formatted=$(calculate_age "$upload_date")
        
        # Use single, bolder checkmark/cross
        if [ "$verified" = "1" ]; then
            # Use heavy/bold checkmark: ✔
            status_symbol="✔"
            status="${GREEN}${status_symbol}${RESET}"
            status_plain="✔"  # Plain version for file (no color codes)
        else
            # Use heavy/bold cross: ✖
            status_symbol="✖"
            status="${RED}${status_symbol}${RESET}"
            status_plain="✖"  # Plain version for file (no color codes)
        fi
        
        # Format file size using format_size function
        size_formatted=$(format_size "$file_size")
        
        # Print to terminal with colors
        printf "%-50s %-32s %-32s " "$filename" "$actual_md5" "$expected_md5"
        echo -ne "$status"
        printf "%5s" ""
        printf "%12s %12s %10s\n" "$size_formatted" "$time_formatted" "$age_formatted"
        
        # Print to file without color codes (time and age are right-aligned to match header)
        printf "%-50s %-32s %-32s %-6s %12s %12s %10s\n" "$filename" "$actual_md5" "$expected_md5" "$status_plain" "$size_formatted" "$time_formatted" "$age_formatted" >> "$log_file"
    done
    
    echo ""
    output_both "=========================================="
    output_both "Totals:"
    output_both "  Total files: $total"
    output_both "  Files processed: $completed_count"
    output_both "  Download failures: $download_failed"
    output_both "  Verification failures: $verify_failed"
    
    # Calculate cumulative size of all successfully downloaded files
    local total_size_bytes=0
    for i in "${!result_file_size[@]}"; do
        local file_size="${result_file_size[$i]}"
        if [ "$file_size" != "N/A" ] && [ "$file_size" != "Failed Download" ]; then
            total_size_bytes=$((total_size_bytes + file_size))
        fi
    done
    
    # Format and display total size
    local total_size_formatted=$(format_size "$total_size_bytes")
    output_both "  Total amount downloaded: $total_size_formatted"

    # Calculate and display total script run time
    local script_end_epoch
    script_end_epoch=$(date +%s)
    local total_runtime=$((script_end_epoch - script_start_epoch))
    output_both "  Total time: $(format_time $total_runtime)"
    echo ""

    # Mirror the log file into the per-run log directory so a complete
    # summary travels with the per-download logs.
    if [ -f "$log_file" ] && [ -d "$LOG_DIR" ]; then
        cp "$log_file" "$LOG_DIR/000-Download-Test-Summary.txt"
    fi
}

# Worker: downloads one file into a per-job dir, verifies MD5, writes result line
download_worker() {
    local idx=$1
    local hash=$2
    local filename=$3
    local expected_md5=$4
    local upload_date=$5
    local num=$((idx + 1))
    local work_dir="$RESULTS_DIR/work-$idx"
    local result_file="$RESULTS_DIR/result-$idx"
    local safe_filename="${filename//\//_}"
    local ant_log
    ant_log=$(printf '%s/%03d-%s.log' "$LOG_DIR" "$num" "$safe_filename")

    mkdir -p "$work_dir"

    echo "[$num/$total] ▶ Starting: $filename"

    local start_time end_time download_time ant_exit_code
    start_time=$(date +%s)
    ant -v file download "$hash" -o "$work_dir/$filename" >"$ant_log" 2>&1
    ant_exit_code=$?
    end_time=$(date +%s)
    download_time=$((end_time - start_time))

    local actual_md5 file_size verified status_msg
    if [ $ant_exit_code -ne 0 ]; then
        actual_md5="Failed Download"
        file_size="Failed Download"
        verified=0
        status_msg="${RED}✗${RESET} Download failed (see $ant_log)"
    elif [ ! -f "$work_dir/$filename" ]; then
        actual_md5="N/A"
        file_size="N/A"
        verified=0
        status_msg="${RED}✗${RESET} File not found after download"
    else
        file_size=$(stat -c%s "$work_dir/$filename" 2>/dev/null || stat -f%z "$work_dir/$filename" 2>/dev/null || echo "0")
        actual_md5=$(md5sum "$work_dir/$filename" | cut -d' ' -f1)
        if [ "$actual_md5" = "$expected_md5" ]; then
            verified=1
            status_msg="${GREEN}✓${RESET} Verified"
        else
            verified=0
            status_msg="${RED}✗${RESET} MD5 mismatch (got $actual_md5)"
        fi
    fi

    # Clean up the downloaded file
    rm -rf "$work_dir"

    # Write result (pipe-delimited)
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$filename" "$actual_md5" "$expected_md5" "$verified" \
        "$download_time" "$file_size" "${upload_date:-N/A}" > "$result_file"

    echo -e "[$num/$total] $status_msg: $filename ($(format_time $download_time))"
}

# Collect worker results into the summary arrays (in input order)
collect_results() {
    result_filenames=()
    result_actual_md5=()
    result_expected_md5=()
    result_verified=()
    result_download_time=()
    result_file_size=()
    result_upload_date=()
    download_failed=0
    verify_failed=0

    for i in "${!downloads[@]}"; do
        local rfile="$RESULTS_DIR/result-$i"
        [ -f "$rfile" ] || continue
        local rf_filename rf_actual_md5 rf_expected_md5 rf_verified rf_download_time rf_file_size rf_upload_date
        IFS='|' read -r rf_filename rf_actual_md5 rf_expected_md5 rf_verified rf_download_time rf_file_size rf_upload_date < "$rfile"
        result_filenames+=("$rf_filename")
        result_actual_md5+=("$rf_actual_md5")
        result_expected_md5+=("$rf_expected_md5")
        result_verified+=("$rf_verified")
        result_download_time+=("$rf_download_time")
        result_file_size+=("$rf_file_size")
        result_upload_date+=("$rf_upload_date")

        if [ "$rf_actual_md5" = "Failed Download" ]; then
            download_failed=$((download_failed + 1))
        elif [ "$rf_verified" != "1" ]; then
            verify_failed=$((verify_failed + 1))
        fi
    done
}

# Signal handler for Ctrl+C (SIGINT)
# Note: Ctrl+Q is terminal flow control (XON), not an interrupt signal.
# Use Ctrl+C to interrupt the script gracefully.
interrupt_handler() {
    echo ""
    echo -e "\n${RED}Interrupt received! Stopping all downloads...${RESET}"
    interrupted=1

    # Kill all running background workers
    local pids
    pids=$(jobs -rp)
    if [ -n "$pids" ]; then
        echo "Stopping background downloads..."
        kill $pids 2>/dev/null
        sleep 0.5
        kill -9 $pids 2>/dev/null
    fi
    wait 2>/dev/null

    # Collect whatever results made it to disk
    collect_results

    print_summary 1
    exit 130  # Exit code 130 is standard for SIGINT
}

# Set up signal trap for Ctrl+C (SIGINT)
trap interrupt_handler SIGINT

# Launch downloads with concurrency limit
download_failed=0
verify_failed=0

echo "Running with $PARALLEL_JOBS parallel download(s)..."
echo ""

for i in "${!downloads[@]}"; do
    if [ $interrupted -eq 1 ]; then
        break
    fi

    # Wait until a worker slot is free
    while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL_JOBS" ]; do
        if [ $interrupted -eq 1 ]; then
            break 2
        fi
        sleep 0.2
    done

    IFS='|' read -r hash filename expected_md5 upload_date <<< "${downloads[$i]}"
    download_worker "$i" "$hash" "$filename" "$expected_md5" "$upload_date" &
done

# Wait for all workers to finish
wait

# Collect results into summary arrays
collect_results

# Print final summary
print_summary 0

# Exit with appropriate code
if [ $interrupted -eq 1 ]; then
    exit 130
elif [ $download_failed -eq 0 ] && [ $verify_failed -eq 0 ]; then
    echo -e "${GREEN}✓${RESET} All files downloaded and verified successfully!"
    exit 0
else
    echo -e "${RED}✗${RESET} Some operations failed"
    exit 1
fi

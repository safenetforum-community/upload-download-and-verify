#!/usr/bin/env bash
set -euo pipefail

# Upload script for ant CLI with cost and time analysis
# Usage: ./upload.sh <filename>

# Configuration - Use environment variable if set, otherwise use default
# Set WALLET_ADDRESS in your ~/.bashrc or ~/.zshrc to override:
# export WALLET_ADDRESS="0x123..."
WALLET_ADDRESS="${WALLET_ADDRESS:-0x123...}"

# Validate wallet address format (must be 0x followed by 40 hex characters)
if [[ ! "$WALLET_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Error: Invalid or missing wallet address!" >&2
    echo "" >&2
    echo "Please set a valid Ethereum address in one of the following ways:" >&2
    echo "  1. Add to your ~/.bashrc or ~/.zshrc:" >&2
    echo "     export WALLET_ADDRESS=\"0x123...\"" >&2
    echo "" >&2
    echo "  2. Or edit this script and set WALLET_ADDRESS on line 10" >&2
    echo "" >&2
    echo "Current value: $WALLET_ADDRESS" >&2
    exit 1
fi

# Convert a hex balance string (no 0x prefix) into a decimal token amount with
# 18 decimal places. Splits into two 48-bit halves so each printf "%d" stays
# inside signed-64-bit range (printf overflows above ~9.2e18 = ~9.2 ETH).
# Per Janey: handles balances up to 2^96 (24 hex digits) which covers any
# plausible ETH or ANT balance.
hex_to_token_amount() {
    local balance_hex="$1"
    local bal_out="0"
    [[ -z "$balance_hex" ]] && { echo "$bal_out"; return; }

    local balance_hex_len="${#balance_hex}"
    local balance_96="$balance_hex"
    if (( balance_hex_len > 24 )); then balance_96="${balance_hex: -24}"; fi
    local b96_len="${#balance_96}"

    local balance_high="0"
    local balance_low="$balance_96"
    if (( b96_len > 12 )); then
        balance_high="${balance_96:0: $(( b96_len - 12 ))}"
        balance_low="${balance_96: -12}"
    fi

    local bal_high_dec bal_low_dec high_shifted
    bal_high_dec=$(printf "%d" "0x$balance_high" 2>/dev/null) || bal_high_dec=0
    bal_low_dec=$(printf "%d" "0x$balance_low" 2>/dev/null) || bal_low_dec=0
    # high half is shifted left 48 bits => multiply by 2^48 = 281474976710656
    high_shifted=$(echo "$bal_high_dec * 281474976710656" | bc -l 2>/dev/null || echo "0")
    bal_out=$(echo "scale=18; ( $high_shifted + $bal_low_dec ) / 1000000000000000000" | bc -l 2>/dev/null || echo "0")

    [[ "${bal_out:0:1}" == "." ]] && bal_out="0$bal_out"
    echo "$bal_out"
}

# Function to get ETH balance from Arbitrum One
get_eth_balance() {
    local wallet_address="$1"
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$wallet_address\",\"latest\"],\"id\":1}" \
        "https://arb1.arbitrum.io/rpc" 2>/dev/null)

    if [[ $? -eq 0 && -n "$response" ]]; then
        local balance_hex=$(echo "$response" | grep -o '"result":"[^"]*"' | sed 's/"result":"0x//' | sed 's/"//')
        hex_to_token_amount "$balance_hex"
    else
        echo "0"
    fi
}

# Function to get ANT token balance from Arbitrum One (ERC-20 balanceOf)
get_ant_balance() {
    local wallet_address="${1:2}"  # strip leading 0x
    local token_contract="0xa78d8321B20c4Ef90eCd72f2588AA985A4BDb684"
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$token_contract\",\"data\":\"0x70a08231000000000000000000000000$wallet_address\"},\"latest\"],\"id\":1}" \
        "https://arb1.arbitrum.io/rpc" 2>/dev/null)

    if [[ $? -eq 0 && -n "$response" ]]; then
        local balance_hex=$(echo "$response" | grep -o '"result":"[^"]*"' | sed 's/"result":"0x//' | sed 's/"//')
        hex_to_token_amount "$balance_hex"
    else
        echo "0"
    fi
}

# Function to get current ETH price in USD
get_eth_price() {
    # Try CoinGecko API first (free, no API key required)
    local response=$(curl -s "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd" 2>/dev/null)
    
    if [[ $? -eq 0 && -n "$response" ]]; then
        local price=$(echo "$response" | grep -o '"usd":[0-9.]*' | sed 's/"usd"://')
        if [[ -n "$price" ]]; then
            echo "$price"
            return 0
        fi
    fi
    
    # Fallback to CoinCap API
    local response=$(curl -s "https://api.coincap.io/v2/assets/ethereum" 2>/dev/null)
    if [[ $? -eq 0 && -n "$response" ]]; then
        local price=$(echo "$response" | grep -o '"priceUsd":"[0-9.]*"' | sed 's/"priceUsd":"//' | sed 's/"//')
        if [[ -n "$price" ]]; then
            echo "$price"
            return 0
        fi
    fi
    
    # Final fallback to a reasonable default
    echo "2000"
}

# Function to get current ANT token price in USD
get_ant_price() {
    # Try CoinGecko API first (ANT token is "autonomi" on CoinGecko)
    local response=$(curl -s "https://api.coingecko.com/api/v3/simple/price?ids=autonomi&vs_currencies=usd" 2>/dev/null)
    
    if [[ $? -eq 0 && -n "$response" ]]; then
        local price=$(echo "$response" | grep -o '"usd":[0-9.]*' | sed 's/"usd"://')
        if [[ -n "$price" ]]; then
            echo "$price"
            return 0
        fi
    fi
    
    # Fallback: Try searching for ANT on CoinCap (might need to search)
    local response=$(curl -s "https://api.coincap.io/v2/assets/aragon" 2>/dev/null)
    if [[ $? -eq 0 && -n "$response" ]]; then
        local price=$(echo "$response" | grep -o '"priceUsd":"[0-9.]*"' | sed 's/"priceUsd":"//' | sed 's/"//')
        if [[ -n "$price" ]]; then
            echo "$price"
            return 0
        fi
    fi
    
    # Final fallback to a reasonable default (ANT price is typically lower than ETH)
    echo "0.50"
}

# Parse flags
NO_MERKLE_FLAG=""
while [[ $# -gt 0 && "$1" == -* ]]; do
    case "$1" in
        -x)
            NO_MERKLE_FLAG="--no-merkle"
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [-x] <filename>" >&2
            exit 1
            ;;
    esac
done

# Check if filename is provided
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [-x] <filename>"
    echo "  -x    Add --no-merkle to upload command"
    echo "Example: $0 usefhiseufh.txt"
    exit 1
fi

FILENAME="$1"

# Check if file exists
if [[ ! -f "$FILENAME" ]]; then
    echo "Error: File '$FILENAME' not found"
    exit 1
fi

# Get file size and MD5 checksum
FILE_SIZE=$(du -h "$FILENAME" | cut -f1)
MD5_ORIGINAL=$(md5sum "$FILENAME" | cut -d' ' -f1)

echo "📁 File: $FILENAME"
echo "📏 Size: $FILE_SIZE"
echo "🔐 MD5: $MD5_ORIGINAL"
echo ""

# Record start time
START_TIME=$(date +%s.%N)

# Get ETH + ANT balances before upload
echo "💰 Checking ETH balance before upload..."
ETH_BALANCE_BEFORE=$(get_eth_balance "$WALLET_ADDRESS")
echo "  ETH Balance Before: $ETH_BALANCE_BEFORE ETH"

echo "💰 Checking ANT balance before upload..."
ANT_BALANCE_BEFORE=$(get_ant_balance "$WALLET_ADDRESS")
echo "  ANT Balance Before: $ANT_BALANCE_BEFORE ANT"

# Upload the file and capture output
echo "🚀 Starting upload..."
echo ""

# Create temporary file for output capture
TEMP_OUTPUT=$(mktemp)

# Run the upload command and capture output while showing it in real-time
ant file upload --public $NO_MERKLE_FLAG "$FILENAME" 2>&1 | tee "$TEMP_OUTPUT"
UPLOAD_EXIT_CODE=${PIPESTATUS[0]}

# Check if upload was successful
if [[ $UPLOAD_EXIT_CODE -ne 0 ]]; then
    echo "❌ Upload failed with exit code $UPLOAD_EXIT_CODE"
    rm -f "$TEMP_OUTPUT"
    exit 1
fi

echo ""

# Get ETH + ANT balances after upload
echo "💰 Checking ETH balance after upload..."
ETH_BALANCE_AFTER=$(get_eth_balance "$WALLET_ADDRESS")
echo "  ETH Balance After: $ETH_BALANCE_AFTER ETH"

echo "💰 Checking ANT balance after upload..."
ANT_BALANCE_AFTER=$(get_ant_balance "$WALLET_ADDRESS")
echo "  ANT Balance After: $ANT_BALANCE_AFTER ANT"

# Calculate actual on-chain costs from balance differences
ETH_GAS_COST=$(echo "scale=18; $ETH_BALANCE_BEFORE - $ETH_BALANCE_AFTER" | bc -l 2>/dev/null || echo "0")
ANT_COST_ONCHAIN=$(echo "scale=18; $ANT_BALANCE_BEFORE - $ANT_BALANCE_AFTER" | bc -l 2>/dev/null || echo "0")
[[ "${ETH_GAS_COST:0:1}" == "." ]] && ETH_GAS_COST="0$ETH_GAS_COST"
[[ "${ETH_GAS_COST:0:1}" == "-" && "${ETH_GAS_COST:1:1}" == "." ]] && ETH_GAS_COST="-0${ETH_GAS_COST:1}"
[[ "${ANT_COST_ONCHAIN:0:1}" == "." ]] && ANT_COST_ONCHAIN="0$ANT_COST_ONCHAIN"
[[ "${ANT_COST_ONCHAIN:0:1}" == "-" && "${ANT_COST_ONCHAIN:1:1}" == "." ]] && ANT_COST_ONCHAIN="-0${ANT_COST_ONCHAIN:1}"
echo "  ETH Gas Cost: $ETH_GAS_COST ETH"
echo "  ANT Cost (on-chain): $ANT_COST_ONCHAIN ANT"

# Record end time
END_TIME=$(date +%s.%N)
UPLOAD_DURATION_SEC=$(printf "%.0f" $(echo "$END_TIME - $START_TIME" | bc))

# Convert duration to hours, minutes, and seconds
UPLOAD_HOURS=$((UPLOAD_DURATION_SEC / 3600))
UPLOAD_MINUTES=$(((UPLOAD_DURATION_SEC % 3600) / 60))
UPLOAD_SECONDS=$((UPLOAD_DURATION_SEC % 60))

# Format duration string with zero-padding (always show hours and minutes)
UPLOAD_DURATION=$(printf "%02dh %02dm %02ds" $UPLOAD_HOURS $UPLOAD_MINUTES $UPLOAD_SECONDS)

echo ""
echo "📊 Upload Analysis:"
echo "=================="

# Extract file address from new output format: "  Address: <hex>"
FILE_ADDRESS=$(grep -oP '^\s*Address:\s*\K[a-f0-9]+' "$TEMP_OUTPUT" || true)

if [[ -z "$FILE_ADDRESS" ]]; then
    echo "❌ Error: Could not extract file address from upload output"
    echo "Upload output:"
    cat "$TEMP_OUTPUT"
    rm -f "$TEMP_OUTPUT"
    exit 1
fi

# Extract number of chunks: "  Chunks:  27"
CHUNKS=$(grep -oP '^\s*Chunks:\s*\K[0-9]+' "$TEMP_OUTPUT" || echo "")

# Extract ANT cost and gas cost from: "  Cost:    0.3164 ANT (gas: 0.000020 ETH)"
TOTAL_COST_ANT_REPORTED=$(grep -oP '^\s*Cost:\s*\K[0-9.]+(?=\s*ANT)' "$TEMP_OUTPUT" || echo "0")
GAS_COST_ETH_REPORTED=$(grep -oP 'gas:\s*\K[0-9.]+(?=\s*ETH)' "$TEMP_OUTPUT" || echo "")

# Prefer on-chain ANT cost (balance diff) over ant CLI's reported value — the
# CLI has been observed reporting wrong amounts (e.g. 4 ANT when actual was 0.6).
# Fall back to reported value only if on-chain diff is non-positive (network blip).
if [[ -n "$ANT_COST_ONCHAIN" ]] && [[ "$(echo "$ANT_COST_ONCHAIN > 0" | bc -l 2>/dev/null)" == "1" ]]; then
    TOTAL_COST_ANT="$ANT_COST_ONCHAIN"
else
    TOTAL_COST_ANT="$TOTAL_COST_ANT_REPORTED"
fi

# Use reported gas cost if available, otherwise use balance-based calculation
if [[ -n "$GAS_COST_ETH_REPORTED" ]]; then
    GAS_COST_ETH="$GAS_COST_ETH_REPORTED"
else
    GAS_COST_ETH="$ETH_GAS_COST"
fi

# Extract upload time from ant output: "  Time:    301.0s"
UPLOAD_TIME_ANT=$(grep -oP '^\s*Time:\s*\K[0-9.]+(?=s)' "$TEMP_OUTPUT" || echo "")

# Extract reported size: "  Size:    93.3 MB"
UPLOAD_SIZE_REPORTED=$(grep -oP '^\s*Size:\s*\K[0-9.]+ [A-Z]+' "$TEMP_OUTPUT" || echo "")

# Done with the captured output
rm -f "$TEMP_OUTPUT"

# Get current ETH price in USD
echo "💰 Fetching current ETH price..."
ETH_PRICE_USD=$(get_eth_price)
echo "  ETH Price: \$$ETH_PRICE_USD"

# Get current ANT token price in USD
echo "💰 Fetching current ANT token price..."
ANT_PRICE_USD=$(get_ant_price)
echo "  ANT Price: \$$ANT_PRICE_USD"

# Calculate USD costs
GAS_COST_USD=$(echo "scale=2; $GAS_COST_ETH * $ETH_PRICE_USD" | bc -l 2>/dev/null || echo "0.00")
ANT_COST_USD=$(echo "scale=2; $TOTAL_COST_ANT * $ANT_PRICE_USD" | bc -l 2>/dev/null || echo "0.00")
TOTAL_COST_USD=$(echo "scale=2; $ANT_COST_USD + $GAS_COST_USD" | bc -l 2>/dev/null || echo "0.00")

# Display results
echo "✅ Upload completed successfully!"
echo ""
echo "📋 Upload Details:"
echo "  File: $FILENAME"
echo "  Size: $FILE_SIZE"
echo "  Address: $FILE_ADDRESS"
echo "  Chunks: $CHUNKS"
echo "  MD5: $MD5_ORIGINAL"
echo ""
echo "💰 Cost Analysis:"
echo "  ANT Cost: $TOTAL_COST_ANT ANT (\$$ANT_COST_USD)  [on-chain; ant CLI reported: $TOTAL_COST_ANT_REPORTED ANT]"
echo "  Gas Cost: $GAS_COST_ETH ETH (\$$GAS_COST_USD)"
echo "  Total USD Cost: \$$TOTAL_COST_USD"
echo ""
echo "⏱️  Time Analysis:"
echo "  Total Duration: ${UPLOAD_DURATION}"
echo ""

# Generate download command with MD5 verification
UPLOAD_DATE=$(date +"%d/%m/%y")
echo "📥 Download Command:"
DOWNLOAD_CMD=$(printf "ant file download %s -o %s  # %s md5sum %s  %s \$%.2f %s" "$FILE_ADDRESS" "$FILENAME" "${UPLOAD_DURATION}" "$MD5_ORIGINAL" "$FILE_SIZE" "$TOTAL_COST_USD" "$UPLOAD_DATE")
echo "$DOWNLOAD_CMD"
echo "$DOWNLOAD_CMD" >> uploads.txt
echo ""
echo "💾 Download command saved to uploads.txt"
echo ""
echo "🎉 Upload analysis complete!"

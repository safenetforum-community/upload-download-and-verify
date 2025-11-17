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

# Function to get ETH balance from Arbitrum One
get_eth_balance() {
    local wallet_address="$1"
    # Use curl to query Arbitrum One RPC endpoint
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$wallet_address\",\"latest\"],\"id\":1}" \
        "https://arb1.arbitrum.io/rpc" 2>/dev/null)
    
    if [[ $? -eq 0 && -n "$response" ]]; then
        # Extract balance from JSON response and convert from hex to decimal
        local balance_hex=$(echo "$response" | grep -o '"result":"[^"]*"' | sed 's/"result":"0x//' | sed 's/"//')
        if [[ -n "$balance_hex" ]]; then
            # Convert hex to decimal (Wei)
            local balance_wei=$(printf "%d" "0x$balance_hex" 2>/dev/null)
            if [[ $? -eq 0 ]]; then
                # Convert Wei to ETH (1 ETH = 10^18 Wei)
                echo "scale=18; $balance_wei / 1000000000000000000" | bc -l 2>/dev/null || echo "0"
            else
                echo "0"
            fi
        else
            echo "0"
        fi
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

# Check if filename is provided
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <filename>"
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

# Get ETH balance before upload
echo "💰 Checking ETH balance before upload..."
ETH_BALANCE_BEFORE=$(get_eth_balance "$WALLET_ADDRESS")
echo "  ETH Balance Before: $ETH_BALANCE_BEFORE ETH"

# Upload the file and capture output
echo "🚀 Starting upload..."
echo ""

# Create temporary file for output capture
TEMP_OUTPUT=$(mktemp)

# Run the upload command and capture output while showing it in real-time
# Use a different approach to ensure proper capture
ant --network-id 1 file upload -p --no-archive --retry-failed 0 "$FILENAME" 2>&1 | tee "$TEMP_OUTPUT"
UPLOAD_EXIT_CODE=${PIPESTATUS[0]}

# Read the output
UPLOAD_OUTPUT=$(cat "$TEMP_OUTPUT")

# Clean up temp file
rm -f "$TEMP_OUTPUT"

# Check if upload was successful
if [[ $UPLOAD_EXIT_CODE -ne 0 ]]; then
    echo "❌ Upload failed with exit code $UPLOAD_EXIT_CODE"
    exit 1
fi

echo ""

# Get ETH balance after upload
echo "💰 Checking ETH balance after upload..."
ETH_BALANCE_AFTER=$(get_eth_balance "$WALLET_ADDRESS")
echo "  ETH Balance After: $ETH_BALANCE_AFTER ETH"

# Calculate ETH gas cost
ETH_GAS_COST=$(echo "scale=18; $ETH_BALANCE_BEFORE - $ETH_BALANCE_AFTER" | bc -l 2>/dev/null || echo "0")
echo "  ETH Gas Cost: $ETH_GAS_COST ETH"

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

# Extract file address from output - try multiple patterns
FILE_ADDRESS=$(echo "$UPLOAD_OUTPUT" | grep "At address:" | sed 's/.*At address: \([a-f0-9]\+\).*/\1/')

# If that didn't work, try the other pattern
if [[ -z "$FILE_ADDRESS" ]]; then
    FILE_ADDRESS=$(echo "$UPLOAD_OUTPUT" | grep "Upload completed for file" | sed 's/.*at \([a-f0-9]\+\).*/\1/')
fi

if [[ -z "$FILE_ADDRESS" ]]; then
    echo "❌ Error: Could not extract file address from upload output"
    echo "Upload output:"
    echo "$UPLOAD_OUTPUT"
    exit 1
fi

# Extract number of chunks
CHUNKS=$(echo "$UPLOAD_OUTPUT" | grep "Processing estimated total" | sed 's/.*total \([0-9]\+\) chunks.*/\1/' || echo "")

# Check if chunks were free (already existed)
FREE_CHUNKS=$(echo "$UPLOAD_OUTPUT" | grep "chunks were free" | sed 's/\([0-9]\+\) chunks were free.*/\1/' || echo "")

# Extract total cost in AttoTokens
TOTAL_COST_ATTO=$(echo "$UPLOAD_OUTPUT" | grep "Total cost:" | sed 's/.*Total cost: \([0-9]\+\).*/\1/' || echo "")

# If no cost found, it means chunks were free
if [[ -z "$TOTAL_COST_ATTO" ]]; then
    TOTAL_COST_ATTO="0"
fi

# Convert AttoTokens to ANT (1 ANT = 10^18 AttoTokens)
if [[ -n "$TOTAL_COST_ATTO" && "$TOTAL_COST_ATTO" != "0" ]]; then
    TOTAL_COST_ANT=$(echo "scale=18; $TOTAL_COST_ATTO / 1000000000000000000" | bc 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        TOTAL_COST_ANT="0"
    fi
else
    TOTAL_COST_ANT="0"
fi

# Extract upload duration from ant output
UPLOAD_DURATION_ANT=$(echo "$UPLOAD_OUTPUT" | grep "Upload completed in" | sed 's/.*in \([0-9\.]\+\)s.*/\1/' || echo "")

# Extract time information from time command (it will be shown in the output)
# We'll use our calculated duration instead
REAL_TIME="${UPLOAD_DURATION}s"
USER_TIME="N/A"
SYS_TIME="N/A"

# Use actual ETH gas cost from balance difference
GAS_COST_ETH="$ETH_GAS_COST"

# Get current ETH price in USD
echo "💰 Fetching current ETH price..."
ETH_PRICE_USD=$(get_eth_price)
echo "  ETH Price: \$$ETH_PRICE_USD"

# Get current ANT token price in USD
echo "💰 Fetching current ANT token price..."
ANT_PRICE_USD=$(get_ant_price)
echo "  ANT Price: \$$ANT_PRICE_USD"

# Calculate USD cost using real ETH price
GAS_COST_USD=$(echo "scale=2; $GAS_COST_ETH * $ETH_PRICE_USD" | bc -l 2>/dev/null || echo "0.00")

# Calculate ANT cost in USD
ANT_COST_USD=$(echo "scale=2; $TOTAL_COST_ANT * $ANT_PRICE_USD" | bc -l 2>/dev/null || echo "0.00")

# Calculate total USD cost (ANT cost + gas cost)
TOTAL_COST_USD=$(echo "scale=2; $ANT_COST_USD + $GAS_COST_USD" | bc -l 2>/dev/null || echo "0.00")

# Display results
echo "✅ Upload completed successfully!"
echo ""
echo "📋 Upload Details:"
echo "  File: $FILENAME"
echo "  Size: $FILE_SIZE"
echo "  Address: $FILE_ADDRESS"
echo "  Chunks: $CHUNKS"
if [[ -n "$FREE_CHUNKS" ]]; then
    echo "  Free Chunks: $FREE_CHUNKS (already existed on network)"
fi
echo "  MD5: $MD5_ORIGINAL"
echo ""
echo "💰 Cost Analysis:"
echo "  ANT Cost: $TOTAL_COST_ANT ANT (\$$ANT_COST_USD)"
echo "  AttoTokens: $TOTAL_COST_ATTO"
echo "  Gas Cost: $GAS_COST_ETH ETH (\$$GAS_COST_USD)"
echo "  Total USD Cost: \$$TOTAL_COST_USD"
echo ""
echo "⏱️  Time Analysis:"
echo "  Total Duration: ${UPLOAD_DURATION}"
echo ""

# Generate download command with MD5 verification
UPLOAD_DATE=$(date +"%d/%m/%y")
echo "📥 Download Command:"
DOWNLOAD_CMD=$(printf "ant file download --retries 20 $FILE_ADDRESS $FILENAME  # ${UPLOAD_DURATION} md5sum $MD5_ORIGINAL  $FILE_SIZE \$%.2f $UPLOAD_DATE" "$TOTAL_COST_USD")
echo "$DOWNLOAD_CMD"
echo "$DOWNLOAD_CMD" >> uploads.txt
echo ""
echo "💾 Download command saved to uploads.txt"
echo ""
echo "🎉 Upload analysis complete!"

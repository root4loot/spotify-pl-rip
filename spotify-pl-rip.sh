#!/bin/bash
if [ $# -ne 4 ]; then
    echo "Usage: ./spotify-pl-rip.sh <spotify_playlist_url> <spotify_client_id> <spotify_client_secret> <output_directory>"
    exit 1
fi

# Command line arguments
PLAYLIST_URL=$1
CLIENT_ID=$2
CLIENT_SECRET=$3
OUTPUT_DIR=$4
LOG_FILE="$OUTPUT_DIR/spotify-pl-rip_errors.log"

# Configurable parameters
TRACK_WAIT_TIME=120           # Time to wait between processing tracks (in seconds)
SYNC_INTERVAL=14400           # Time between playlist syncs (in seconds, 14400 = 4 hours)
MAX_CONVERSION_ATTEMPTS=3     # Maximum number of attempts for Spotify to Tidal conversion
CONVERSION_RETRY_WAIT=30      # Time to wait between conversion retry attempts (in seconds)
ARTIST_MATCH_LENGTH=3         # Number of characters to use for artist name matching
TRACK_MATCH_LENGTH=5          # Number of characters to use for track name matching

if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: Output directory does not exist: $OUTPUT_DIR"
    exit 1
fi

log_error() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "$LOG_FILE"
    echo "[$timestamp] $1"
}

file_exists() {
    local artist=$1
    local name=$2
    
    # Extract first few characters of artist and name (after normalization)
    local normalized_artist=$(echo "$artist" | sed 's/[^a-zA-Z0-9]//g' | tr '[:upper:]' '[:lower:]')
    local normalized_name=$(echo "$name" | sed 's/[^a-zA-Z0-9]//g' | tr '[:upper:]' '[:lower:]')
    
    # Take first few chars for more lenient matching
    local artist_start=${normalized_artist:0:$ARTIST_MATCH_LENGTH}
    local name_start=${normalized_name:0:$TRACK_MATCH_LENGTH}
    
    # Skip if we don't have enough characters to match
    if [ -z "$artist_start" ] || [ -z "$name_start" ]; then
        echo "Warning: Artist or name too short for reliable matching: $artist - $name"
        return 1
    fi
    
    for file in "$OUTPUT_DIR"/*.wav; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file" .wav)
            local normalized_basename=$(echo "$basename" | sed 's/[^a-zA-Z0-9]//g' | tr '[:upper:]' '[:lower:]')
            
            # Check if file contains the start of both artist and name
            if [[ "$normalized_basename" == *"$artist_start"* && "$normalized_basename" == *"$name_start"* ]]; then
                echo "Match found: '$basename' contains artist '$artist_start' and name '$name_start'"
                return 0
            fi
        fi
    done
    
    return 1
}

process_track() {
    local spotify_url=$1
    local artist=$2
    local name=$3
    
    echo "Processing: $artist - $name"
    
    if file_exists "$artist" "$name"; then
        echo "File already exists in output directory, skipping: $artist - $name"
        return
    fi
    
    echo "Converting Spotify URL to Tidal URL: $spotify_url"
    
    # Try up to MAX_CONVERSION_ATTEMPTS times with a delay between attempts
    local attempt=1
    local tidal_response=""
    
    while [ $attempt -le $MAX_CONVERSION_ATTEMPTS ]; do
        echo "Attempt $attempt of $MAX_CONVERSION_ATTEMPTS to convert Spotify URL to Tidal URL"
        tidal_response=$(python /app/spotify-to-tidal/spotify-to-tidal.py "$spotify_url")
        echo "Tidal conversion response: $tidal_response"
        
        # Check if conversion was successful
        if echo "$tidal_response" | grep -q "\"status\": \"success\""; then
            break
        fi
        
        # Log the error
        local error_message=$(echo "$tidal_response" | grep -o "\"message\": \"[^\"]*\"" | cut -d'"' -f4)
        echo "Conversion attempt $attempt failed: $error_message"
        
        if [ $attempt -lt $MAX_CONVERSION_ATTEMPTS ]; then
            echo "Waiting $CONVERSION_RETRY_WAIT seconds before retrying..."
            sleep $CONVERSION_RETRY_WAIT
        fi
        
        attempt=$((attempt + 1))
    done
    
    # Check if conversion failed after all attempts
    if ! echo "$tidal_response" | grep -q "\"status\": \"success\""; then
        local error_message=$(echo "$tidal_response" | grep -o "\"message\": \"[^\"]*\"" | cut -d'"' -f4)
        log_error "Failed to convert to Tidal URL after $MAX_CONVERSION_ATTEMPTS attempts: $artist - $name ($spotify_url). Error: $error_message"
        return
    fi
    
    # Extract Tidal URL
    local tidal_url=$(echo "$tidal_response" | grep -o "\"tidal_url\": \"[^\"]*\"" | cut -d'"' -f4)
    echo "Successfully converted to Tidal URL: $tidal_url"
    
    echo "Downloading track from Tidal: $tidal_url"
    local download_response=$(python /app/tidalrip/tidalrip.py "$tidal_url" -o "$OUTPUT_DIR")
    echo "Tidal download response: $download_response"
    
    if echo "$download_response" | grep -q "\"status\": \"success\""; then
        local file_path=$(echo "$download_response" | grep -o "\"file_path\": \"[^\"]*\"" | cut -d'"' -f4)
        
        echo "Converting to WAV: $file_path"
        local wav_file="${file_path%.flac}.wav"
        ffmpeg -i "$file_path" -c:a pcm_s16le -metadata comment="" -metadata ICMT="" "$wav_file" -y
        
        rm "$file_path"
        
        echo "Successfully processed: $artist - $name"
    else
        local download_error=$(echo "$download_response" | grep -o "\"message\": \"[^\"]*\"" | cut -d'"' -f4)
        log_error "Failed to download track: $artist - $name ($tidal_url). Error: $download_error"
    fi
}

get_spotify_tracks() {
    echo "Getting tracks from Spotify playlist: $PLAYLIST_URL"
    local result=$(python /app/spotify-playlist/spotify-playlist.py "$PLAYLIST_URL" "$CLIENT_ID" "$CLIENT_SECRET")
    echo "$result"
}

sync_tracks() {
    echo "Syncing tracks from Spotify playlist: $PLAYLIST_URL"
    local tracks=$(get_spotify_tracks)
    
    echo "$tracks" | while read -r track; do
        if [ -n "$track" ]; then
            local artist=$(echo "$track" | grep -o "\"artist\": \"[^\"]*\"" | cut -d'"' -f4)
            local name=$(echo "$track" | grep -o "\"name\": \"[^\"]*\"" | cut -d'"' -f4)
            local url=$(echo "$track" | grep -o "\"url\": \"[^\"]*\"" | cut -d'"' -f4)
            
            # Skip tracks with empty artist or name
            if [ -z "$artist" ] || [ -z "$name" ] || [ -z "$url" ]; then
                echo "Skipping invalid track data: $track"
                continue
            fi
            
            process_track "$url" "$artist" "$name"
            
            echo "Waiting $TRACK_WAIT_TIME seconds before processing next track..."
            sleep $TRACK_WAIT_TIME
        fi
    done
    
    echo "Sync completed"
}

while true; do
    sync_tracks
    
    echo "Waiting $SYNC_INTERVAL seconds ($(($SYNC_INTERVAL/3600)) hours) before next sync..."
    sleep $SYNC_INTERVAL
done
#!/bin/bash
if [ $# -ne 4 ]; then
    echo "Usage: ./spotify-pl-rip.sh <spotify_playlist_url> <spotify_client_id> <spotify_client_secret> <output_directory>"
    exit 1
fi

PLAYLIST_URL=$1
CLIENT_ID=$2
CLIENT_SECRET=$3
OUTPUT_DIR=$4
LOG_FILE="$OUTPUT_DIR/spotify-pl-rip_errors.log"

TRACK_WAIT_TIME=120
SYNC_INTERVAL=14400
MAX_CONVERSION_ATTEMPTS=3
CONVERSION_RETRY_WAIT=30
ARTIST_MATCH_LENGTH=3
TRACK_MATCH_LENGTH=5

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
    
    local normalized_artist=$(echo "$artist" | sed 's/[^a-zA-Z0-9]//g' | tr '[:upper:]' '[:lower:]')
    local normalized_name=$(echo "$name" | sed 's/[^a-zA-Z0-9]//g' | tr '[:upper:]' '[:lower:]')
    
    local artist_start=${normalized_artist:0:$ARTIST_MATCH_LENGTH}
    local name_start=${normalized_name:0:$TRACK_MATCH_LENGTH}
    
    if [ -z "$artist_start" ] || [ -z "$name_start" ]; then
        echo "Warning: Artist or name too short for reliable matching: $artist - $name"
        return 1
    fi
    
    for file in "$OUTPUT_DIR"/*.wav; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file" .wav)
            local normalized_basename=$(echo "$basename" | sed 's/[^a-zA-Z0-9]//g' | tr '[:upper:]' '[:lower:]')
            
            if [[ "$normalized_basename" == *"$artist_start"* && "$normalized_basename" == *"$name_start"* ]]; then
                echo "Match found: '$basename' contains artist '$artist_start' and name '$name_start'"
                return 0
            fi
        fi
    done
    
    return 1
}

cleanup_flac_files() {
    echo "Looking for remaining FLAC files in $OUTPUT_DIR..."
    
    local flac_files=$(find "$OUTPUT_DIR" -name "*.flac" -type f)
    
    if [ -z "$flac_files" ]; then
        echo "No FLAC files found."
        return
    fi
    
    echo "Found FLAC files to convert:"
    echo "$flac_files"
    
    echo "$flac_files" | while read -r flac_path; do
        if [ -f "$flac_path" ]; then
            echo "Converting: $flac_path"
            local wav_path="${flac_path%.flac}.wav"
            
            ffmpeg -i "$flac_path" -c:a pcm_s16le -metadata comment="" -metadata ICMT="" "$wav_path" -y
            
            if [ -f "$wav_path" ]; then
                echo "WAV conversion successful. Removing original FLAC file."
                rm -f "$flac_path"
            else
                echo "WAV conversion failed. FLAC file not removed."
            fi
        fi
    done
    
    echo "FLAC cleanup completed."
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
    
    local attempt=1
    local tidal_response=""
    
    while [ $attempt -le $MAX_CONVERSION_ATTEMPTS ]; do
        echo "Attempt $attempt of $MAX_CONVERSION_ATTEMPTS to convert Spotify URL to Tidal URL"
        tidal_response=$(python /app/spotify-to-tidal/spotify-to-tidal.py "$spotify_url")
        echo "Tidal conversion response: $tidal_response"
        
        if echo "$tidal_response" | grep -q "\"status\": \"success\""; then
            break
        fi
        
        local error_message=$(echo "$tidal_response" | grep -o "\"message\": \"[^\"]*\"" | cut -d'"' -f4)
        echo "Conversion attempt $attempt failed: $error_message"
        
        if [ $attempt -lt $MAX_CONVERSION_ATTEMPTS ]; then
            echo "Waiting $CONVERSION_RETRY_WAIT seconds before retrying..."
            sleep $CONVERSION_RETRY_WAIT
        fi
        
        attempt=$((attempt + 1))
    done
    
    if ! echo "$tidal_response" | grep -q "\"status\": \"success\""; then
        local error_message=$(echo "$tidal_response" | grep -o "\"message\": \"[^\"]*\"" | cut -d'"' -f4)
        log_error "Failed to convert to Tidal URL after $MAX_CONVERSION_ATTEMPTS attempts: $artist - $name ($spotify_url). Error: $error_message"
        return
    fi
    
    local tidal_url=$(echo "$tidal_response" | grep -o "\"tidal_url\": \"[^\"]*\"" | cut -d'"' -f4)
    echo "Successfully converted to Tidal URL: $tidal_url"
    
    echo "Downloading track from Tidal: $tidal_url"
    local download_response=$(python /app/tidalrip/tidalrip.py "$tidal_url" -o "$OUTPUT_DIR")
    echo "Tidal download response: $download_response"
    
    if echo "$download_response" | grep -q "\"status\": \"success\""; then
        local flac_path=""
        
        # First try to find the actual file that was downloaded
        if echo "$download_response" | grep -q "\"file_path\":"; then
            flac_path=$(echo "$download_response" | grep -o "\"file_path\": \"[^\"]*\"" | cut -d'"' -f4)
        elif echo "$download_response" | grep -q "\"path\":"; then
            flac_path=$(echo "$download_response" | grep -o "\"path\": \"[^\"]*\"" | cut -d'"' -f4)
        fi
        
        # If we have a path but the file doesn't exist, or no path was found
        if [ -z "$flac_path" ] || [ ! -f "$flac_path" ]; then
            echo "FLAC file not found at expected path. Searching for recently created FLAC files..."
            local recent_flac=$(find "$OUTPUT_DIR" -name "*.flac" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d" ")
            
            if [ -n "$recent_flac" ] && [ -f "$recent_flac" ]; then
                echo "Found recent FLAC file: $recent_flac"
                flac_path="$recent_flac"
            else
                log_error "Could not locate downloaded FLAC file for $artist - $name"
                return
            fi
        fi
        
        # Define the target WAV file name using Spotify metadata
        local target_wav="$OUTPUT_DIR/$artist - $name.wav"
        
        echo "Converting: $flac_path"
        echo "To WAV with Spotify metadata: $target_wav"
        
        # Convert to WAV with Spotify metadata
        ffmpeg -i "$flac_path" -c:a pcm_s16le -metadata title="$name" -metadata artist="$artist" -metadata comment="" -metadata ICMT="" "$target_wav" -y
        
        if [ -f "$target_wav" ]; then
            echo "WAV conversion successful. Removing original FLAC file."
            rm -f "$flac_path"
        else
            echo "WAV conversion failed. FLAC file not removed."
        fi
        
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
    cleanup_flac_files
}

while true; do
    sync_tracks
    
    echo "Waiting $SYNC_INTERVAL seconds ($(($SYNC_INTERVAL/3600)) hours) before next sync..."
    sleep $SYNC_INTERVAL
done
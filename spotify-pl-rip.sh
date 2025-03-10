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
CACHED_TRACKS_FILE="$OUTPUT_DIR/cached_tracks.json"

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

decode_unicode() {
    local input="$1"
    python3 -c "import sys; print(sys.argv[1].encode('utf-8').decode('unicode_escape'))" "$input"
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
    
    local decoded_artist=$(decode_unicode "$artist")
    local decoded_name=$(decode_unicode "$name")
    
    echo "Processing: $decoded_artist - $decoded_name"
    
    if file_exists "$decoded_artist" "$decoded_name"; then
        echo "File already exists in output directory, skipping: $decoded_artist - $decoded_name"
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
        log_error "Failed to convert to Tidal URL after $MAX_CONVERSION_ATTEMPTS attempts: $decoded_artist - $decoded_name ($spotify_url). Error: $error_message"
        return
    fi
    
    local tidal_url=$(echo "$tidal_response" | grep -o "\"tidal_url\": \"[^\"]*\"" | cut -d'"' -f4)
    echo "Successfully converted to Tidal URL: $tidal_url"
    
    echo "Downloading track from Tidal: $tidal_url"
    local download_response=$(python /app/tidalrip/tidalrip.py "$tidal_url" -o "$OUTPUT_DIR")
    echo "Tidal download response: $download_response"
    
    if echo "$download_response" | grep -q "\"status\": \"success\""; then
        local flac_path=""
        
        if echo "$download_response" | grep -q "\"file_path\":"; then
            flac_path=$(echo "$download_response" | grep -o "\"file_path\": \"[^\"]*\"" | cut -d'"' -f4)
        elif echo "$download_response" | grep -q "\"path\":"; then
            flac_path=$(echo "$download_response" | grep -o "\"path\": \"[^\"]*\"" | cut -d'"' -f4)
        else
            echo "No file path provided in response, searching for recently created FLAC files..."
            local recent_flac=$(find "$OUTPUT_DIR" -name "*.flac" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d" ")
            
            if [ -n "$recent_flac" ] && [ -f "$recent_flac" ]; then
                echo "Found recent FLAC file: $recent_flac"
                flac_path="$recent_flac"
            else
                log_error "Could not locate downloaded FLAC file for $decoded_artist - $decoded_name"
                return
            fi
        fi
        
        if [ -f "$flac_path" ]; then
            local wav_path="$OUTPUT_DIR/$decoded_artist - $decoded_name.wav"
            echo "Converting to WAV using Spotify metadata: $wav_path"
            
            ffmpeg -i "$flac_path" -c:a pcm_s16le -metadata artist="$decoded_artist" -metadata title="$decoded_name" -metadata comment="" -metadata ICMT="" "$wav_path" -y
            
            if [ -f "$wav_path" ]; then
                echo "WAV conversion successful. Removing original FLAC file."
                rm -f "$flac_path"
                echo "Successfully processed: $decoded_artist - $decoded_name"
            else
                echo "WAV conversion failed. FLAC file not removed."
                log_error "Failed to convert FLAC to WAV: $flac_path"
            fi
        else
            log_error "FLAC file not found: $flac_path"
        fi
    else
        local download_error=$(echo "$download_response" | grep -o "\"message\": \"[^\"]*\"" | cut -d'"' -f4)
        log_error "Failed to download track: $decoded_artist - $decoded_name ($tidal_url). Error: $download_error"
    fi
}

get_spotify_tracks() {
    echo "Getting tracks from Spotify playlist: $PLAYLIST_URL"
    local result=$(python /app/spotify-playlist/spotify-playlist.py "$PLAYLIST_URL" "$CLIENT_ID" "$CLIENT_SECRET")
    echo "$result"
}

find_new_tracks() {
    local current_tracks=$(get_spotify_tracks)
    local new_tracks=()
    
    if [ ! -f "$CACHED_TRACKS_FILE" ]; then
        echo "[]" > "$CACHED_TRACKS_FILE"
    fi
    
    echo "Identifying new tracks in playlist..."
    
    echo "$current_tracks" | while read -r track; do
        if [ -n "$track" ]; then
            local artist=$(echo "$track" | grep -o "\"artist\": \"[^\"]*\"" | cut -d'"' -f4)
            local name=$(echo "$track" | grep -o "\"name\": \"[^\"]*\"" | cut -d'"' -f4)
            local url=$(echo "$track" | grep -o "\"url\": \"[^\"]*\"" | cut -d'"' -f4)
            local decoded_artist=$(decode_unicode "$artist")
            local decoded_name=$(decode_unicode "$name")
            
            if [ -z "$artist" ] || [ -z "$name" ] || [ -z "$url" ]; then
                echo "Skipping invalid track data: $track"
                continue
            fi
            
            if ! file_exists "$decoded_artist" "$decoded_name"; then
                echo "New track found: $decoded_artist - $decoded_name"
                process_track "$url" "$artist" "$name"
                echo "Waiting $TRACK_WAIT_TIME seconds before processing next track..."
                sleep $TRACK_WAIT_TIME
            else
                echo "Track already exists: $decoded_artist - $decoded_name"
            fi
        fi
    done
    
    echo "$current_tracks" > "$CACHED_TRACKS_FILE"
}

sync_tracks() {
    echo "Starting sync for Spotify playlist: $PLAYLIST_URL"
    
    find_new_tracks
    
    echo "Sync completed"
    cleanup_flac_files
}

while true; do
    sync_tracks
    
    echo "Waiting $SYNC_INTERVAL seconds ($(($SYNC_INTERVAL/3600)) hours) before next sync..."
    sleep $SYNC_INTERVAL
done
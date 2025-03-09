# spotify-pl-rip

Download tracks from Tidal based on a Spotify playlist and convert them to WAV format.

## Setup

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/spotify-pl-rip.git
   cd spotify-pl-rip
   ```

2. Create a `.env` file with the following contents:
   ```
   SPOTIFY_PLAYLIST_URL=https://open.spotify.com/playlist/your_playlist_id
   SPOTIFY_CLIENT_ID=your_spotify_client_id
   SPOTIFY_CLIENT_SECRET=your_spotify_client_secret
   OUTPUT_DIR=/path/to/your/music/directory
   ```

3. Make sure the directory specified in `OUTPUT_DIR` exists.

## Usage

Start the container with Docker Compose:

```bash
docker-compose up -d
```

Monitor the logs:
```bash
docker-compose logs -f
```

## How It Works

The script uses:
- [spotify-playlist](https://github.com/root4loot/spotify-playlist) to get tracks from Spotify
- [spotify-to-tidal](https://github.com/root4loot/spotify-to-tidal) to convert URLs
- [tidalrip](https://github.com/root4loot/tidalrip) to download tracks from Tidal
- ffmpeg to convert FLAC to WAV

## Note
- Only works with public playlists
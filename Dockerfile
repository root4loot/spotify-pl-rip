FROM python:3.9-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    git \
    jq \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/root4loot/spotify-playlist.git && \
    git clone https://github.com/root4loot/spotify-to-tidal.git && \
    git clone https://github.com/root4loot/tidalrip.git

RUN pip install --no-cache-dir requests spotipy

COPY spotify-pl-rip.sh /app/
RUN chmod +x /app/spotify-pl-rip.sh

ENTRYPOINT ["/app/spotify-pl-rip.sh"]
# Aria backend image. Use it through compose.yaml; see docs/SELF-HOSTING.md.
FROM python:3.12-slim-trixie

# ffmpeg extracts and validates audio. yt-dlp runs YouTube's player JS in Node.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg nodejs \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt app.py library_index.py docker-entrypoint.sh /app/

# The venv belongs to the runtime user so yt-dlp can update itself.
# The default extra adds yt-dlp-ejs, which yt-dlp needs for full YouTube support.
RUN useradd --create-home --uid 10001 aria \
    && python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r /app/requirements.txt 'yt-dlp[default]' \
    && chown -R aria:aria /opt/venv \
    && chmod +x /app/docker-entrypoint.sh \
    && install -d -o aria -g aria /data

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1

USER aria

# app.py keeps its song cache and library index relative to the working
# directory, so this puts them on the /data volume.
WORKDIR /data

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/api/health', timeout=4)"

ENTRYPOINT ["/app/docker-entrypoint.sh"]

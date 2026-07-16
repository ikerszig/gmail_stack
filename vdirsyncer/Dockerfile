FROM python:3.12-slim

# [google] extra pulls in aiohttp-oauthlib, required by the google_calendar storage
RUN pip install --no-cache-dir "vdirsyncer[google]"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

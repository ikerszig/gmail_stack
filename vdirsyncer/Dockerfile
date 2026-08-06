FROM python:3.12-slim

# [google] extra pulls in aiohttp-oauthlib, required by the google_calendar storage
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

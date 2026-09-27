# WakeBack server (server/app.py + the viewer) as a container, for the NAS or the dock Pi.
# Built by GitHub on every change: ghcr.io/jb65uk/wakeback-server:latest (amd64 + arm64).
FROM python:3.12-slim
WORKDIR /app
COPY server/requirements.txt server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt
COPY server/ server/
COPY viewer/ viewer/
ENV PYTHONUNBUFFERED=1
# sessions, venues, pucks: keep this folder on the NAS so updates never touch your data
VOLUME /app/data
EXPOSE 5000
HEALTHCHECK --interval=60s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/api/hello', timeout=4)"
# one process (the server keeps files consistent with an in-process lock), several threads for many phones
CMD ["gunicorn", "--workers", "1", "--threads", "8", "--bind", "0.0.0.0:5000", "--timeout", "180", "--chdir", "server", "app:app"]

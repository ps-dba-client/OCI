FROM python:3.11-slim-bookworm

WORKDIR /function

ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY func.py /function/func.py

# FDK 0.1.109+ expects the fdk CLI as entrypoint (not python -m / fdk.handle).
ENTRYPOINT ["/usr/local/bin/fdk", "/function/func.py", "handler"]

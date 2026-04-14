FROM python:3.11-slim-bookworm

WORKDIR /function

ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY entrypoint.sh /function/entrypoint.sh
RUN chmod +x /function/entrypoint.sh

COPY func.py /function/func.py

# Splunk auto-instrumentation wrapper → FDK
ENTRYPOINT ["/function/entrypoint.sh"]

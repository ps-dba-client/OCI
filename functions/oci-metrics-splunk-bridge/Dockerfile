FROM python:3.11-slim-bookworm

WORKDIR /function

ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY func.py /function/func.py

# FDK runs the handler; opentelemetry-instrument loads the Splunk OTEL distro and instrumentors
# (set OTEL_PYTHON_DISTRO=splunk_distro on the Functions app).
ENTRYPOINT ["opentelemetry-instrument", "/usr/local/bin/fdk", "/function/func.py", "handler"]

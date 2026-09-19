FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt constraints.txt .
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc python3-dev \
    && pip install --no-cache-dir -r requirements.txt -c constraints.txt \
    && apt-get purge -y gcc python3-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY app.py .

RUN useradd --uid 1000 --user-group --create-home --home-dir /home/collector \
        --shell /usr/sbin/nologin collector \
    && chmod 755 /app \
    && chmod 644 /app/app.py

USER collector

CMD ["python", "-u", "app.py"]

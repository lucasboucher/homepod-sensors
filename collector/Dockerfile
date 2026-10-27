FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt constraints.txt .
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates gcc python3-dev \
    && python -m pip install --no-cache-dir \
      "pip @ https://files.pythonhosted.org/packages/3f/06/3e4420302363fbb71be3c7f35ce042f54bfca330e3e66b3a2e3c4cca579f/pip-26.2.2-py3-none-any.whl#sha256=fd7f4dfa8190e014013b9f08f3e973f4e4c26ffd179a204895533a7254813a70" \
    && python -m pip --version \
    && python -m pip install --no-cache-dir -r requirements.txt -c constraints.txt \
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

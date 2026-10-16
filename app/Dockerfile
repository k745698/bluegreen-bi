FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN useradd --system --no-create-home portal
USER portal

EXPOSE 8000
# --graceful-timeout: on SIGTERM, finish in-flight requests for up to 20 s
# (inside the pod's 30 s terminationGracePeriodSeconds, after the 5 s preStop).
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--graceful-timeout", "20", "app:app"]

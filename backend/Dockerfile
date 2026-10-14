FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5000

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates/ templates/
COPY static/ static/

# Run as an unprivileged user.
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 5000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2).status == 200 else 1)"

# 3 processes x 16 threads = 48 requests in flight per backend; a deep backlog absorbs bursts.
# --preload creates the shared request counter before the workers fork.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--preload", "--workers", "3", "--threads", "16", \
     "--backlog", "2048", "--access-logfile", "-", "app:app"]

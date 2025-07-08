# ───────────────────────────
# Stage 1: build & runtime image
# ───────────────────────────
FROM python:3.12-slim

# 1. Working directory
WORKDIR /app

# 2. Core runtime env flags
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=3978

# 3. (Optional) OS build tools – only include what you need
RUN apt-get update && \
    apt-get install -y gcc && \
    rm -rf /var/lib/apt/lists/*

# 4. Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# 5. Copy application code
COPY . .

# 6. Make the container advertise the port
EXPOSE 3978

# 7. Drop root – create a non-privileged user
RUN adduser --disabled-password --gecos '' appuser && \
    chown -R appuser:appuser /app
USER appuser

# 8. Entrypoint
CMD ["python", "app.py"]

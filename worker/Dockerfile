FROM python:3.11-slim

WORKDIR /app

# Install system deps if needed
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

# Copy worker code
COPY run_codex_job.py /app/run_codex_job.py

# Workspace is mounted here
VOLUME ["/workspace"]
WORKDIR /workspace

CMD ["python", "/app/run_codex_job.py"]

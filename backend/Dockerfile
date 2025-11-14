FROM python:3.11-slim

WORKDIR /app

# Install docker CLI for 'docker run' from inside backend container
RUN apt-get update && apt-get install -y docker.io && rm -rf /var/lib/apt/lists/*

COPY ./requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY ./app /app/app
COPY ./main.py /app/main.py
COPY ./alembic.ini /app/alembic.ini
COPY ./alembic /app/alembic
COPY ./tests /app/tests
COPY ./docker-entrypoint.sh /app/docker-entrypoint.sh

ENV PYTHONUNBUFFERED=1

RUN chmod +x /app/docker-entrypoint.sh

EXPOSE 8000

CMD ["bash", "/app/docker-entrypoint.sh"]

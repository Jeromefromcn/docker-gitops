FROM python:3.12.7-alpine3.20
WORKDIR /app
COPY config.py app.py switches.ini ./
COPY switches/ ./switches/
CMD ["python3", "app.py"]

FROM python:3.12.7-alpine3.20
# The official image ships the stdlib without .pyc files. Every status.sh is a
# fresh python3 process running as uid 1001, which can't write the stdlib's
# __pycache__/ — so each import tried (and failed) to create a uniquely named
# "<mod>.pyc.<id>" temp file, leaving one negative dentry per attempt. At ccr's
# refresh rate that piled up ~1G of reclaimable kernel slab charged to this
# container. Precompile at build time (as root) and never try to write again.
RUN python3 -m compileall -q /usr/local/lib/python3.12
ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY config.py app.py switches.ini ./
COPY switches/ ./switches/
CMD ["python3", "app.py"]

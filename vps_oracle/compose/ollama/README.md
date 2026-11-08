# ollama

A shared Ollama instance for local embedding (and small-model) inference, for any app on this host. CPU only (no GPU on this host).

Installed models: `nomic-embed-text` (768-dim). Planned: `bge-m3`, `bge-small-en-v1.5`.

## No prod/dev split

Unlike the minio/postgres/redis shared resources, there is **no `<app>` / `<app>_dev` pool split here**. Models are stateless, read-only weights shared by every caller — there is no per-app data to isolate. prod and dev of an app both call the same instance and models. (The resulting vectors are stored in the app's own isolated pools, e.g. `elasticsearch`'s `<app>-*` / `<app>_dev-*`.)

## Architecture

| container_name | network | host port | data |
|---|---|---|---|
| `ollama` | `ollama_default` | `127.0.0.1:11434` only | `/etc/ollama` (bind mount: models + server key) |

Not on `proxy`, no NPM record, no homepage card (no UI) and no Prometheus target — same as the other shared backends.

## Why it isn't exposed publicly

**Ollama has no authentication.** Anyone who can reach the port can pull/delete models, fill the disk, and burn the CPU. The port binds `127.0.0.1` (allowlisted in `PORT_EXCEPTIONS` in `.github/scripts/check-compose-conventions.py`); containers reach it over `ollama_default`. Never add it to `proxy` or NPM, and don't put an auth proxy in front of it to "open it up" — use it from this host only.

## Resource limits

- `cpus: 3`, `memory: 2.5G`. Embedding models are small (nomic ≈ 270 MB, bge-m3 ≈ 1.2 GB); don't load a model that won't fit in 2.5G.
- `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`: one model in memory, one request at a time; switching models unloads the previous one, and concurrent callers queue.
- **Clients pass `"options": {"num_thread": 3}`** to match the CPU limit, so the thread count isn't derived from the host's core count rather than the 3-CPU cgroup cap.
- The CPU caps of this stack (3) and `elasticsearch` (2) add up to more than the host's 4 cores. They are caps, not reservations — under simultaneous full load the two compete.

## Connecting a new app

No credentials. Just the URL:

- from a container: join the network and use `http://ollama:11434`
  ```yaml
  services:
    app:
      networks: [ollama]
  networks:
    ollama:
      name: ollama_default
      external: true
  ```
- from the host: `http://127.0.0.1:11434`

```bash
curl -s 127.0.0.1:11434/api/embed \
  -d '{"model":"nomic-embed-text","input":"text to embed","options":{"num_thread":3}}' \
  | jq '.embeddings[0] | length'     # 768
```

## Models

Pull a model (one line; persisted in `/etc/ollama`):

```bash
docker exec ollama ollama pull <model>
```

| model | pull name | note |
|---|---|---|
| nomic-embed-text | `nomic-embed-text` | installed, 768-dim |
| bge-m3 | `bge-m3` | in the Ollama library, 1024-dim |
| bge-small-en-v1.5 | `hf.co/<user>/bge-small-en-v1.5-gguf` | **not** in the Ollama library — pull a GGUF build from Hugging Face; check the repo exists first |

List / remove: `docker exec ollama ollama list`, `docker exec ollama ollama rm <model>`.

## First install

```bash
cd /home/ubuntu/jerome/docker-gitops/vps_oracle/compose/ollama
sudo mkdir -p /etc/ollama
docker compose up -d
docker exec ollama ollama pull nomic-embed-text
```

## Gotchas

- The image ships no tzdata; the zone file is mounted so Go honors `TZ` (logs are `+08:00`).

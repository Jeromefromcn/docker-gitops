# ollama-openwebui

## 内存占用现状（2026-08-01 记录）

```
open-webui   ~1.1GiB RSS（单个 python3 uvicorn 进程，模型未加载时的空跑基线）
ollama       ~30MiB（还没 pull/load 任何模型）
主机         24GB 总，当前 10GB 已用 / 13GB 可用
```

`open-webui` 这 ~1.1GB 不是配置问题或内存泄漏，是官方镜像默认会在启动时把下面这套本地 ML 依赖 import 进同一个进程，不管你用不用：

| 库 | 用途 | 触发场景 |
|---|---|---|
| `torch` (CPU) + `transformers` + `sentence-transformers` | 默认 embedding 模型 `all-MiniLM-L6-v2`（`RAG_EMBEDDING_ENGINE` 默认为空 = 本地跑） | 知识库 / RAG 功能 |
| `chromadb` | 内置向量数据库 | 同上，存 embedding 结果 |
| `faster-whisper` + `onnxruntime` | 本地语音转文字（`WHISPER_MODEL` 默认 `base`，`AUDIO_STT_ENGINE` 默认为空 = 本地跑） | 语音输入 |

这台机器内存还有 13GB 余量，目前**没有改动配置**——现状够用，先记录下来，等以后内存紧张了再按下面的选项收。

## 可选：如果以后要压内存，能关掉的

以 `env_file`/`environment` 加到 `open-webui` 服务里，改完 `docker compose up -d` 生效：

- **把 embedding 交给 Ollama 算**，不在 open-webui 进程里加载 `torch`/`sentence-transformers`（省内存最大的一块）：
  ```yaml
  RAG_EMBEDDING_ENGINE: "ollama"
  RAG_EMBEDDING_MODEL: "nomic-embed-text"   # 需要额外 ollama pull nomic-embed-text
  ```
  代价：知识库检索改成调用 Ollama API，多一次网络往返；不用知识库/RAG 功能的话直接设这个也没副作用。

- **语音转文字改用远程引擎，不在本地跑 faster-whisper**：
  ```yaml
  AUDIO_STT_ENGINE: "openai"   # 需要配 AUDIO_STT_OPENAI_API_BASE_URL / API_KEY 指向兼容的 STT 服务
  ```
  没有可用的远程 STT 服务的话，这项就没法关，只能忍着本地 whisper 的开销；不用语音输入功能时影响也不大（未触发前不会真正加载模型权重，但 `faster-whisper`/`onnxruntime` 包本身仍会被 import）。

- **两项都不改**：现状继续用，`torch`/`chromadb`/`faster-whisper` 常驻内存，换来开箱即用的 RAG + 语音输入，不用额外配置。

## 快速复查内存占用

```bash
docker stats --no-stream ollama open-webui
```

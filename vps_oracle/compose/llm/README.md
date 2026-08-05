# llm

## 后端说明（2026-08-01 记录）

原本用 `ollama` 做后端，现在换成 Ampere 官方针对 Ampere Altra（OCI A1 用的这颗 CPU）优化过的
`amperecomputingai/llama.cpp`，走 router 模式（`--models-dir`），支持在已下载好的多个模型间不重启切换。
`open-webui` 和 `sillytavern` 都通过它的 OpenAI 兼容端点（`http://llama-cpp:8080/v1`）接入，共享同一个后端。
细节和取舍看 `docker-compose.yml` 里 `llama-cpp` 服务的注释。

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

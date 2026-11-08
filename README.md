# Local AI Gateway

> OpenAI 兼容的本地多模态推理服务（NVIDIA GPU）
>
> 文本(Qwen) + 生图(Flux/SDXL) + 视频(Wan/CogVideoX) + TTS(Kokoro) + ASR(Whisper)
> 全部无 UI、纯后端、通过统一 `/v1` 接口调用

## 架构

```
你的后台应用
    │
    ▼
┌─────────────────────────────────────┐
│  API Gateway  :8000  (FastAPI)       │
│  ├─ API Key 鉴权中间件                │
│  ├─ Redis 任务队列                    │
│  └─ SSE 进度推送                      │
├─────────────────────────────────────┤
│  /v1/chat/completions    → Ollama    │
│  /v1/images/generations  → SDCPP     │
│  /v1/videos              → Video Wkr │
│  /v1/audio/speech        → Kokoro    │
│  /v1/audio/transcriptions→ faster-whisper │
│  /v1/agent/create        → qwen导演   │
└─────────────────────────────────────┘
```

## 快速开始

```bash
# 1. 安装环境（依赖 / Ollama / 编译 SDCPP / Redis）
chmod +x scripts/*.sh
./scripts/install.sh

# 2. 下载模型权重（交互式选择，走 hf-mirror 国内镜像）
./scripts/download_models.sh
#   非交互（自动选轻量集：Flux Q4 + Wan2.1 1.3B + Kokoro + whisper-turbo）：
./scripts/download_models.sh --auto

# 3. 启动
./scripts/start.sh

# 4. 测试
./scripts/test.sh
```

> `install.sh` **只装环境，不下权重**。权重由 `download_models.sh` 负责；
> 也可以自己从别处拷模型，按下面的目录放好即可。

## 模型权重说明

默认根目录 `~/.local-ai-models`（可用环境变量 `MODEL_DIR` 改，记得同步改 `.env`）：

```
~/.local-ai-models/
├── sd/                                  # 生图
│   ├── flux1-schnell-q4_k_m.gguf        # Flux 主模型（city96/FLUX.1-Schnell-gguf）
│   ├── clip_l.safetensors               # Flux 文本编码器（comfyanonymous/flux_text_encoders）
│   ├── t5xxl_fp16.safetensors           # 显存紧可用 t5xxl_fp8_e4m3fn
│   ├── ae.safetensors                   # VAE（black-forest-labs/FLUX.1-schnell，需登录同意协议）
│   └── sdxl-base-1.0/                   # SDXL（stabilityai/stable-diffusion-xl-base-1.0）
├── video/                               # 视频（diffusers 目录，含 config.json）
│   ├── wan2.1-t2v-1.3b/                 # Wan-AI/Wan2.1-T2V-1.3B-Diffusers
│   ├── cogvideox-2b/                    # THUDM/CogVideoX-2b
│   └── t5-v1_1-xxl/                     # CogVideoX 文本编码器（可选，缺失则首次运行自动下）
├── tts/kokoro-82m/                      # hexgrad/Kokoro-82M（含 voices/）
└── asr/faster-whisper-large-v3-turbo/   # Systran/faster-whisper-large-v3-turbo
```

### 按显存推荐组合

| 显存 | 生图 | 视频 | ASR |
|---|---|---|---|
| 6–8GB | Flux Q4 / Z-Image | Wan2.1 1.3B / CogVideoX-2B | medium / small |
| 12–16GB | Flux fp8 / SDXL | Wan2.1 14B GGUF / LTX-13B | large-v3-turbo |
| 24GB+ | 多模型同载 | Wan2.1 14B fp16 / HunyuanVideo | large-v3 |

### 镜像与登录

- 国内下载慢：脚本默认 `HF_ENDPOINT=https://hf-mirror.com`，可 `export HF_MIRROR=...` 改。
- FLUX 的 `ae.safetensors` 需要先在 HuggingFace 登录并同意许可：
  ```bash
  huggingface-cli login
  # 然后重跑 ./scripts/download_models.sh
  ```

### 验证权重是否齐全

```bash
ls -lh ~/.local-ai-models/sd/*.gguf ~/.local-ai-models/sd/*.safetensors
ls ~/.local-ai-models/video/*/config.json
ls ~/.local-ai-models/tts/kokoro-82m/voices/ | head
ls ~/.local-ai-models/asr/*/config.json
```

## 接口一览

| 接口 | 说明 |
|---|---|
| `POST /v1/chat/completions` | 文本对话（OpenAI 格式） |
| `POST /v1/images/generations` | 生图（OpenAI 格式） |
| `POST /v1/videos` | 视频生成（异步，返回 job_id） |
| `GET /v1/videos/{id}` | 查询视频任务状态 |
| `GET /v1/videos/{id}/stream` | SSE 实时进度 |
| `POST /v1/audio/speech` | TTS 语音合成（OpenAI 格式） |
| `POST /v1/audio/transcriptions` | ASR 语音转写（OpenAI 格式） |
| `POST /v1/agent/create` | Agent 全自动编排 |
| `GET /v1/models` | 列出可用模型 |

## 客户端调用

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="local-ai-gateway-secret-key",
)

# 文本
client.chat.completions.create(
    model="qwen",
    messages=[{"role": "user", "content": "你好"}]
)

# 生图
client.images.generate(model="flux", prompt="...", size="1024x1024")

# TTS
client.audio.speech.create(model="kokoro", input="Hello", voice="af_sarah")
```

## Agent 编排

让 qwen 当导演，自动串联全流程：

```python
import httpx
httpx.post("http://localhost:8000/v1/agent/create", json={
    "instruction": "做一个赛博朋克城市宣传短片",
    "mode": "full",
    "num_clips": 3,
    "duration_per_clip": 3,
})
# 返回 job_id，轮询 /v1/agent/{id} 获取结果
```

流程：`qwen生成剧本+分镜` → `Flux生图` → `Wan图生视频` → `Kokoro配音` → `汇总`

## Docker 部署

```bash
cd deploy
export API_KEY="your-secret-key"
export MODEL_DIR="/path/to/models"
docker-compose up -d
```

## 目录结构

```
local-ai-gateway/
├── gateway/            # API 网关
│   ├── main.py         # 入口
│   ├── config.py       # 配置
│   ├── models.py       # Pydantic 模型
│   ├── middleware/     # 鉴权
│   ├── routers/        # 路由
│   └── agent/          # Agent 编排
├── workers/            # 推理 worker
│   ├── sdcpp/          # 生图 (C++ CUDA)
│   ├── kokoro/         # TTS
│   ├── asr/            # Whisper
│   └── video/          # 视频生成
├── deploy/             # Docker 部署
├── scripts/            # 安装/启动/停止/测试
├── examples/           # 客户端示例
└── requirements.txt
```

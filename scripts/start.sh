#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."

# ---------- 平台检测（与 install.sh 一致） ----------
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
    *)                    IS_WINDOWS=0 ;;
esac

# Git Bash 下没有 sudo / systemctl；Linux 下以 root 运行时也不需要 sudo
if [ "$IS_WINDOWS" -eq 1 ] || ! command -v sudo >/dev/null 2>&1 || [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# ---------- venv ----------
# Windows venv 布局在 Scripts/（install.sh 也会生成 venv/bin/activate 转发层，双保险）
if [ -f venv/Scripts/activate ]; then
    source venv/Scripts/activate
else
    source venv/bin/activate
fi
mkdir -p logs

# MODEL_DIR 优先级: 环境变量 > .env > 默认
MODEL_DIR="${MODEL_DIR:-$(grep -E '^MODEL_DIR=' .env 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"' || true)}"
MODEL_DIR="${MODEL_DIR:-$HOME/.local-ai-models}"

echo "🚀 Starting Local AI Gateway..."
echo "   API Key: $(grep -E '^API_KEY=' .env 2>/dev/null | head -n1 | cut -d= -f2 || echo 'local-ai-gateway-secret-key')"
echo ""

# 1. Ollama
echo "▶ Starting Ollama..."
if ! ollama list >/dev/null 2>&1; then
    if [ "$IS_WINDOWS" -eq 1 ]; then
        echo "   Ollama 服务未响应，后台启动 ollama serve..."
        nohup ollama serve >/dev/null 2>&1 &
    else
        $SUDO systemctl is-active --quiet ollama || $SUDO systemctl start ollama
    fi
    sleep 2
fi
ollama list >/dev/null 2>&1 || echo "   ⚠️  Ollama 未就绪，chat 接口将不可用"

# 2. Redis
echo "▶ Starting Redis..."
redis_ping() {
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli ping 2>/dev/null | grep -q PONG
    else
        # Windows 常没有 redis-cli，退化为探测 6379 端口
        (echo > /dev/tcp/127.0.0.1/6379) >/dev/null 2>&1
    fi
}
if ! redis_ping; then
    if [ "$IS_WINDOWS" -eq 1 ]; then
        echo "   Redis 未运行，尝试启动..."
        if command -v redis-server >/dev/null 2>&1; then
            nohup redis-server >/dev/null 2>&1 &
        elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            docker start redis >/dev/null 2>&1 || \
                docker run -d --name redis -p 6379:6379 redis:7-alpine >/dev/null 2>&1 || true
        fi
    else
        $SUDO systemctl is-active --quiet redis-server || $SUDO systemctl start redis-server
    fi
    sleep 2
fi
redis_ping || echo "   ⚠️  Redis 未就绪，视频任务队列将不可用"

# 3. SDCPP REST
echo "▶ Starting SDCPP REST API..."
SDCPP_BIN=""
for p in \
    "workers/sdcpp/stable-diffusion.cpp/build/bin/sd-server.exe" \
    "workers/sdcpp/stable-diffusion.cpp/build/sd-server.exe" \
    "workers/sdcpp/stable-diffusion.cpp/build/sd-rest-api.exe" \
    "workers/sdcpp/stable-diffusion.cpp/build/Release/sd-rest-api.exe" \
    "workers/sdcpp/stable-diffusion.cpp/build/sd-rest-api"; do
    if [ -f "$p" ]; then SDCPP_BIN="$p"; break; fi
done
if [ -n "$SDCPP_BIN" ]; then
    case "$SDCPP_BIN" in
        *sd-server*)
            # 新版 sd-server：--listen-ip/--listen-port/--model-dir（CUDA 已编译进二进制，产物在 build\bin\）
            nohup "$SDCPP_BIN" \
                --listen-ip 0.0.0.0 \
                --listen-port 8080 \
                --model-dir "$MODEL_DIR/sd" \
                > logs/sdcpp.log 2>&1 &
            ;;
        *)
            # 旧版 sd-rest-api
            nohup "$SDCPP_BIN" \
                --host 0.0.0.0 \
                --port 8080 \
                --models-path "$MODEL_DIR/sd" \
                --cuda \
                --threads 8 \
                > logs/sdcpp.log 2>&1 &
            ;;
    esac
    echo $! > /tmp/sdcpp.pid
    echo "   SDCPP PID: $(cat /tmp/sdcpp.pid)"
else
    echo "   ⚠️  SDCPP binary not found, starting Docker container instead..."
    if [ "$IS_WINDOWS" -eq 1 ]; then
        # docker.exe 挂载需要 Windows 路径；MSYS_NO_PATHCONV 防止 Git Bash 再转换
        MODELS_WIN="$(cygpath -w "$MODEL_DIR/sd" 2>/dev/null || echo "$MODEL_DIR/sd")"
        MSYS_NO_PATHCONV=1 docker run -d --name sdcpp --gpus all -p 8080:8080 \
            -v "${MODELS_WIN}:/models" \
            local-ai-gateway-sdcpp 2>/dev/null || true
    else
        docker run -d --name sdcpp --gpus all -p 8080:8080 \
            -v "$MODEL_DIR/sd:/models" \
            local-ai-gateway-sdcpp 2>/dev/null || true
    fi
fi

# 4. Kokoro TTS
echo "▶ Starting Kokoro TTS..."
nohup python workers/kokoro/main.py > logs/kokoro.log 2>&1 &
echo $! > /tmp/kokoro.pid
echo "   Kokoro PID: $(cat /tmp/kokoro.pid)"

# 5. ASR Worker
echo "▶ Starting ASR Worker..."
nohup python workers/asr/main.py > logs/asr.log 2>&1 &
echo $! > /tmp/asr.pid
echo "   ASR PID: $(cat /tmp/asr.pid)"

# 6. Video Worker
echo "▶ Starting Video Worker..."
nohup python workers/video/main.py > logs/video_worker.log 2>&1 &
echo $! > /tmp/video_worker.pid
echo "   Video Worker PID: $(cat /tmp/video_worker.pid)"

# 7. Gateway
echo "▶ Starting API Gateway..."
nohup python -m uvicorn gateway.main:app --host 0.0.0.0 --port 8000 > logs/gateway.log 2>&1 &
echo $! > /tmp/gateway.pid
echo "   Gateway PID: $(cat /tmp/gateway.pid)"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✅ 所有服务已启动                                ║"
echo "║                                                  ║"
echo "║  Gateway:     http://localhost:8000              ║"
echo "║  API Docs:    http://localhost:8000/docs         ║"
echo "║  Health:      http://localhost:8000/health       ║"
echo "║                                                  ║"
echo "║  日志目录:    logs/                                ║"
echo "║  停止服务:    ./scripts/stop.sh                    ║"
echo "╚══════════════════════════════════════════════════╝"

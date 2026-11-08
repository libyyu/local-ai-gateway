#!/usr/bin/env bash
set -e

# =============================================================
#  Local AI Gateway — 模型权重下载脚本
#  只下载权重，不装环境（环境由 install.sh 负责）
#  支持交互式选择 + 非交互式（--auto 轻量集）
#
#  目录约定（sd-server 新版按类别子目录扫描）:
#    $MODEL_DIR/sd/diffusion_models/   量化 diffusion 模型（gguf）
#    $MODEL_DIR/sd/checkpoints/        完整格式主模型（safetensors）
#    $MODEL_DIR/sd/text_encoders/      clip / t5 等文本编码器
#    $MODEL_DIR/sd/vae/                VAE
#  下载新的生图模型后，需在 gateway/routers/images.py 的
#  SDCPP_MODEL_MAP 登记映射（flux 已内置）
# =============================================================

cd "$(dirname "$0")/.."

# 尝试激活项目 venv（huggingface_hub 装在 venv 里）
if [ -f venv/Scripts/activate ]; then
    source venv/Scripts/activate
elif [ -f venv/bin/activate ]; then
    source venv/bin/activate
fi

MODEL_DIR="${MODEL_DIR:-$HOME/.local-ai-models}"
# 国内默认走 hf-mirror；国外可 export HF_MIRROR=https://huggingface.co
HF_MIRROR="${HF_MIRROR:-https://hf-mirror.com}"
AUTO_MODE=0
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=1

echo "=================================================="
echo "  Model Download Script"
echo "  Target : $MODEL_DIR"
echo "  Mirror : $HF_MIRROR"
echo "=================================================="

mkdir -p "$MODEL_DIR"/sd/{diffusion_models,checkpoints,text_encoders,vae} \
         "$MODEL_DIR"/{video,tts,asr}

# --- 依赖检查 ---
# 注意: huggingface_hub 必须 <1.0（requirements.txt 的 transformers 4.45 不兼容 2.x）
# 中文 GBK 控制台下必须设 UTF-8，否则 CLI 打印警告字符会崩溃
export PYTHONIOENCODING=utf-8
if ! command -v hf >/dev/null 2>&1; then
    echo "[*] Installing huggingface_hub CLI..."
    pip install "huggingface_hub[cli]<1.0"
fi
export HF_ENDPOINT="$HF_MIRROR"

# 小工具：下载失败不中断整脚本
# 用新版 `hf download`；老 `huggingface-cli download` 在中文控制台会编码崩溃
dl() {
    echo "  → hf download $*"
    hf download "$@" || echo "  [!] 下载失败，可稍后重试或手动下载（见 README）"
}

choose() {  # choose "提示" 默认值
    if [[ $AUTO_MODE -eq 1 ]]; then echo "$2"; return; fi
    local ans
    read -rp "$1 [$2]: " ans
    echo "${ans:-$2}"
}

# =============================================================
# 1. 生图模型（sd-server）
# =============================================================
echo ""
echo "--- [1/4] 生图模型 ---"
echo "  a) Flux.1 Schnell Q4_K_S (~6GB,  推荐, 快且质量好)"
echo "  b) SDXL Base 1.0         (~7GB,  生态成熟, LoRA 多)"
echo "  c) Z-Image Turbo Q4      (~4GB,  中英文渲染强)"
echo "  d) 以上全部"
echo "  s) 跳过"
IMG="$(choose '选择' 'a')"
case "$IMG" in
    a) dl city96/FLUX.1-Schnell-gguf flux1-schnell-Q4_K_S.gguf --local-dir "$MODEL_DIR/sd/diffusion_models" ;;
    b) dl stabilityai/stable-diffusion-xl-base-1.0 --local-dir "$MODEL_DIR/sd/checkpoints/sdxl-base-1.0" ;;
    c) dl leejet/stable-diffusion.cpp z_image_turbo-Q4_K_M.gguf --local-dir "$MODEL_DIR/sd/diffusion_models"
       ls "$MODEL_DIR/sd/diffusion_models"/z_image* >/dev/null 2>&1 || \
           echo "  [!] Z-Image 可从 Comfy-Org 或 leejet 仓库手动获取 gguf 放入 $MODEL_DIR/sd/diffusion_models" ;;
    d)
       dl city96/FLUX.1-Schnell-gguf flux1-schnell-Q4_K_S.gguf --local-dir "$MODEL_DIR/sd/diffusion_models"
       dl stabilityai/stable-diffusion-xl-base-1.0 --local-dir "$MODEL_DIR/sd/checkpoints/sdxl-base-1.0"
       ;;
    s) echo "  跳过" ;;
esac

# Flux 配套 clip/t5/vae（Flux 必需）
if [[ "$IMG" == "a" || "$IMG" == "d" ]]; then
    echo "  → 下载 Flux 配套 clip_l / t5xxl_fp8 / vae"
    dl comfyanonymous/flux_text_encoders clip_l.safetensors --local-dir "$MODEL_DIR/sd/text_encoders"
    # 显存 12GB+ 可换 t5xxl_fp16.safetensors（~9.4GB，精度更高）
    dl comfyanonymous/flux_text_encoders t5xxl_fp8_e4m3fn.safetensors --local-dir "$MODEL_DIR/sd/text_encoders"
    # VAE: 官方 black-forest-labs 仓库需登录并同意协议，改用 diffusers 同权重镜像
    dl diffusers/FLUX.1-vae diffusion_pytorch_model.safetensors --local-dir "$MODEL_DIR/sd/vae"
    [ -f "$MODEL_DIR/sd/vae/diffusion_pytorch_model.safetensors" ] && \
        mv "$MODEL_DIR/sd/vae/diffusion_pytorch_model.safetensors" "$MODEL_DIR/sd/vae/ae.safetensors"
fi

# =============================================================
# 2. 视频模型（diffusers 格式目录）
# =============================================================
echo ""
echo "--- [2/4] 视频模型 ---"
echo "  a) Wan2.1 T2V 1.3B  (~27GB 全仓含 UMT5 编码器, 8GB 显存需 CPU offload, 最快, 推荐)"
echo "  b) Wan2.1 T2V 14B   (~60GB+, 12GB+ 显存, 高质量)"
echo "  c) CogVideoX-2B     (~5GB,  8GB 显存, 中文提示词友好)"
echo "  d) LTX-Video 13B    (~9GB,  12GB 显存, 速度快)"
echo "  f) 轻量全部 (a+c)"
echo "  s) 跳过"
VID="$(choose '选择' 'a')"
case "$VID" in
    a) dl Wan-AI/Wan2.1-T2V-1.3B-Diffusers --local-dir "$MODEL_DIR/video/wan2.1-t2v-1.3b" ;;
    b) dl Wan-AI/Wan2.1-T2V-14B-Diffusers --local-dir "$MODEL_DIR/video/wan2.1-t2v-14b" ;;
    c) dl THUDM/CogVideoX-2b --local-dir "$MODEL_DIR/video/cogvideox-2b" ;;
    d) dl Lightricks/LTX-Video-13B --local-dir "$MODEL_DIR/video/ltx-video-13b" 2>/dev/null \
       || echo "  [!] LTX 官方仓库名以 huggingface 为准，请手动下载到 $MODEL_DIR/video" ;;
    f)
       dl Wan-AI/Wan2.1-T2V-1.3B-Diffusers --local-dir "$MODEL_DIR/video/wan2.1-t2v-1.3b"
       dl THUDM/CogVideoX-2b --local-dir "$MODEL_DIR/video/cogvideox-2b"
       ;;
    s) echo "  跳过" ;;
esac

# CogVideoX 需要独立 T5 文本编码器（首次运行会自动下，这里预拉）
if [[ "$VID" == "c" || "$VID" == "f" ]]; then
    echo "  → 预拉 CogVideoX 所需 google/t5-v1_1-xxl (较大, 可跳过)"
    dl google/t5-v1_1-xxl --local-dir "$MODEL_DIR/video/t5-v1_1-xxl" || echo "  [!] 首次推理时会自动下载"
fi

# =============================================================
# 3. TTS（Kokoro-82M + 音色）
# =============================================================
echo ""
echo "--- [3/4] TTS 模型 (Kokoro-82M) ---"
read -rp "下载 Kokoro-82M + 音色包？[Y/n]: " TTS_YN
TTS_YN="${TTS_YN:-Y}"
if [[ "$TTS_YN" =~ ^[Yy] ]]; then
    dl hexgrad/Kokoro-82M --local-dir "$MODEL_DIR/tts/kokoro-82m"
    echo "  ✓ 音色在 kokoro-82m/voices/ 下（含 af_sarah 等；中文用 zh_* 音色）"
else
    echo "  跳过"
fi

# =============================================================
# 4. ASR（faster-whisper CTranslate2 格式）
# =============================================================
echo ""
echo "--- [4/4] ASR 模型 (faster-whisper) ---"
echo "  a) large-v3       (~3GB,  最准, 推荐)"
echo "  b) large-v3-turbo (~1.6GB, 快且准)"
echo "  c) medium         (~1.5GB, 均衡)"
echo "  d) small          (~500MB, 最快)"
echo "  s) 跳过"
ASR="$(choose '选择' 'b')"
case "$ASR" in
    a) dl Systran/faster-whisper-large-v3 --local-dir "$MODEL_DIR/asr/faster-whisper-large-v3"
       ls "$MODEL_DIR/asr/faster-whisper-large-v3"/*.safetensors >/dev/null 2>&1 || \
           dl deepdml/faster-whisper-large-v3-ct2 --local-dir "$MODEL_DIR/asr/faster-whisper-large-v3" ;;
    b) dl deepdml/faster-whisper-large-v3-turbo-ct2 --local-dir "$MODEL_DIR/asr/faster-whisper-large-v3-turbo"
       ls "$MODEL_DIR/asr/faster-whisper-large-v3-turbo"/*.safetensors >/dev/null 2>&1 || \
           dl Systran/faster-whisper-large-v3-turbo --local-dir "$MODEL_DIR/asr/faster-whisper-large-v3-turbo" ;;
    c) dl Systran/faster-whisper-medium --local-dir "$MODEL_DIR/asr/faster-whisper-medium" ;;
    d) dl Systran/faster-whisper-small --local-dir "$MODEL_DIR/asr/faster-whisper-small" ;;
    s) echo "  跳过" ;;
esac

# =============================================================
# 完成
# =============================================================
echo ""
echo "=================================================="
echo "  下载完成。当前模型目录："
echo "=================================================="
if command -v tree >/dev/null 2>&1; then
    tree -L 2 -h "$MODEL_DIR"
else
    du -sh "$MODEL_DIR"/* 2>/dev/null
fi

echo ""
echo "下一步："
echo "  1. 确认 .env 中 MODEL_DIR 与本脚本 Target 一致（start.sh 按它找模型）"
echo "  2. ./scripts/start.sh"
echo "  3. ./scripts/test.sh"
echo ""
echo "提示："
echo "  - 生图模型按 sd/diffusion_models|checkpoints|text_encoders|vae 分类存放，"
echo "    新模型需在 gateway/routers/images.py 的 SDCPP_MODEL_MAP 登记 recipe 映射（flux 已内置）"
echo "  - 大文件下载中断可直接重跑本脚本，已完成的文件会自动跳过（断点续传）"

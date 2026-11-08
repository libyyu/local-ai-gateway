"""Models 列表"""
from fastapi import APIRouter

router = APIRouter()

# 可用模型清单
AVAILABLE_MODELS = [
    {"id": "qwen", "object": "model", "owned_by": "ollama", "type": "text"},
    {"id": "qwen-vl", "object": "model", "owned_by": "ollama", "type": "vision"},
    {"id": "deepseek", "object": "model", "owned_by": "ollama", "type": "text"},
    {"id": "flux", "object": "model", "owned_by": "sdcpp", "type": "image"},
    {"id": "sdxl", "object": "model", "owned_by": "sdcpp", "type": "image"},
    {"id": "wan2.1-1.3b", "object": "model", "owned_by": "video-worker", "type": "video"},
    {"id": "kokoro", "object": "model", "owned_by": "kokoro", "type": "tts"},
    {"id": "whisper-large-v3", "object": "model", "owned_by": "asr-worker", "type": "asr"},
]


@router.get("/models")
async def list_models():
    return {"object": "list", "data": AVAILABLE_MODELS}

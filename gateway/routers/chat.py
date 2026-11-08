"""Chat Completions → Ollama"""
import httpx
from fastapi import APIRouter, Request, Response

from gateway.config import settings

router = APIRouter()

# model 别名映射
MODEL_MAP = {
    "qwen": settings.OLLAMA_TEXT_MODEL,
    "qwen-vl": settings.OLLAMA_VL_MODEL,
    "deepseek": "deepseek-r1:7b",
    "llama": "llama3.1:8b",
    "phi": "phi3:mini",
}


@router.post("/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()

    # model 映射
    if body.get("model") in MODEL_MAP:
        body["model"] = MODEL_MAP[body["model"]]

    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.post(
            f"{settings.OLLAMA_BASE_URL}/chat/completions",
            json=body,
            headers={"Authorization": f"Bearer {settings.OLLAMA_API_KEY}"},
        )
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            media_type=resp.headers.get("content-type", "application/json"),
        )

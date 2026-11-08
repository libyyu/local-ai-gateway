"""Audio Speech (TTS) → Kokoro"""
import httpx
from fastapi import APIRouter, Request, Response

from gateway.config import settings

router = APIRouter()


@router.post("/audio/speech")
async def audio_speech(request: Request):
    """
    OpenAI-compatible TTS: POST /v1/audio/speech
    Body: {"model": "kokoro", "input": "...", "voice": "af_sarah", "response_format": "mp3"}
    """
    body = await request.json()

    kokoro_payload = {
        "model": body.get("model", "kokoro"),
        "input": body.get("input", ""),
        "voice": body.get("voice", "af_sarah"),
        "response_format": body.get("response_format", "mp3"),
        "speed": body.get("speed", 1.0),
    }

    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.post(
            f"{settings.KOKORO_URL}/v1/audio/speech",
            json=kokoro_payload,
        )
        fmt = body.get("response_format", "mp3")
        media = f"audio/{fmt}" if fmt != "pcm" else "application/octet-stream"
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            media_type=media,
        )

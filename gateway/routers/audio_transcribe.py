"""Audio Transcription (ASR) → faster-whisper"""
import httpx
from fastapi import APIRouter, UploadFile, File, Form

from gateway.config import settings

router = APIRouter()


@router.post("/audio/transcriptions")
async def audio_transcriptions(
    file: UploadFile = File(...),
    model: str = Form("whisper-large-v3"),
    language: str = Form(None),
    response_format: str = Form("json"),
):
    """
    OpenAI-compatible: POST /v1/audio/transcriptions
    multipart/form-data: file, model, language, response_format
    """
    async with httpx.AsyncClient(timeout=300) as client:
        files = {"file": (file.filename, await file.read(), file.content_type)}
        data = {"model": model, "response_format": response_format}
        if language:
            data["language"] = language

        resp = await client.post(
            f"{settings.ASR_URL}/transcribe",
            files=files,
            data=data,
        )
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            media_type=resp.headers.get("content-type", "application/json"),
        )

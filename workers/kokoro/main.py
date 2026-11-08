"""
Kokoro TTS Worker
OpenAI 兼容的 /v1/audio/speech 接口
"""
import io
import subprocess
import numpy as np
import torch
import uvicorn
from fastapi import FastAPI, Request, Response
from pydantic import BaseModel

app = FastAPI(title="Kokoro TTS Worker")

try:
    from kokoro import KPipeline
    _pipeline = None

    def get_pipeline():
        global _pipeline
        if _pipeline is None:
            _pipeline = KPipeline(lang_code='a', device='cuda' if torch.cuda.is_available() else 'cpu')
        return _pipeline
except ImportError:
    print("[WARN] kokoro not installed, using fallback TTS")
    _pipeline = None


class SpeechRequest(BaseModel):
    model: str = "kokoro"
    input: str = ""
    voice: str = "af_sarah"
    response_format: str = "mp3"
    speed: float = 1.0


def _pcm_to_wav(pcm_data: bytes, sample_rate: int = 24000) -> bytes:
    """PCM s16le → WAV"""
    buf = io.BytesIO()
    with io.BytesIO() as pcm_buf:
        pcm_buf.write(pcm_data)
        pcm_buf.seek(0)
        # Use scipy or wave
        import wave
        wav_buf = io.BytesIO()
        with wave.open(wav_buf, 'wb') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(pcm_buf.read())
        return wav_buf.getvalue()


def _pcm_to_mp3(pcm_data: bytes, sample_rate: int = 24000) -> bytes:
    """PCM s16le → MP3 via ffmpeg"""
    proc = subprocess.run(
        ["ffmpeg", "-f", "s16le", "-ar", str(sample_rate), "-ac", "1", "-i", "pipe:0",
         "-f", "mp3", "-b:a", "128k", "pipe:1"],
        input=pcm_data, capture_output=True
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode()}")
    return proc.stdout


@app.post("/v1/audio/speech")
async def speech(req: SpeechRequest):
    if _pipeline is None:
        # Fallback: 返回静音（生产环境建议装 espeak 或 piper）
        return Response(content=b"", media_type="audio/mpeg", status_code=503)

    generator = get_pipeline()(req.input, voice=req.voice, speed=req.speed)
    audio_chunks = []
    for _, _, audio in generator:
        audio_chunks.append(audio.cpu().numpy())

    if not audio_chunks:
        return Response(content=b"", media_type="audio/mpeg")

    full_audio = np.concatenate(audio_chunks)
    pcm = (full_audio * 32767).astype(np.int16).tobytes()

    if req.response_format == "wav":
        wav_data = _pcm_to_wav(pcm)
        return Response(content=wav_data, media_type="audio/wav")
    elif req.response_format == "pcm":
        return Response(content=pcm, media_type="application/octet-stream")
    else:  # mp3
        mp3_data = _pcm_to_mp3(pcm)
        return Response(content=mp3_data, media_type="audio/mpeg")


@app.get("/health")
async def health():
    return {"status": "ok", "pipeline_loaded": _pipeline is not None}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8880)

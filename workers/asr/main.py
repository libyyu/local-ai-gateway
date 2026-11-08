"""
faster-whisper ASR Worker
OpenAI 兼容的 /transcribe 接口
"""
import uvicorn
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse
import numpy as np
import io

app = FastAPI(title="ASR Worker")

try:
    from faster_whisper import WhisperModel
    _model = None
    _current_model_size = None

    def get_model(size: str = "large-v3"):
        global _model, _current_model_size
        if _model is None or _current_model_size != size:
            device = "cuda" if __import__("torch").cuda.is_available() else "cpu"
            _model = WhisperModel(size, device=device, compute_type="float16" if device == "cuda" else "int8")
            _current_model_size = size
        return _model
except ImportError:
    print("[WARN] faster-whisper not installed")
    _model = None


def _decode_audio(audio_bytes: bytes, filename: str) -> tuple[np.ndarray, int]:
    """用 ffmpeg 解码音频为 16kHz 单声道 PCM"""
    import subprocess
    proc = subprocess.run(
        ["ffmpeg", "-i", "pipe:0", "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"],
        input=audio_bytes, capture_output=True
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg decode failed: {proc.stderr.decode()}")

    audio = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0
    return audio, 16000


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form("whisper-large-v3"),
    language: str = Form(None),
    response_format: str = Form("json"),
):
    if _model is None:
        return JSONResponse(
            status_code=503,
            content={"error": "faster-whisper not installed. pip install faster-whisper"},
        )

    model_size = model.replace("whisper-", "")
    whisper = get_model(model_size)

    # 读取并解码音频
    audio_bytes = await file.read()
    audio_array, sample_rate = _decode_audio(audio_bytes, file.filename)

    # 推理
    segments, info = whisper.transcribe(
        audio_array,
        language=language,
        vad_filter=True,
        beam_size=5,
    )

    segments_list = []
    full_text = []
    for seg in segments:
        segments_list.append({
            "id": seg.id,
            "start": seg.start,
            "end": seg.end,
            "text": seg.text,
        })
        full_text.append(seg.text)

    result = {
        "text": "".join(full_text),
        "language": info.language,
        "language_probability": info.language_probability,
        "duration": info.duration,
        "segments": segments_list,
    }

    if response_format == "text":
        return result["text"]
    elif response_format == "verbose_json":
        return result
    else:
        return result


@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": _model is not None}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8881)

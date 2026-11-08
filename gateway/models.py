"""Pydantic 请求/响应模型"""
from pydantic import BaseModel
from typing import Optional, Literal


# ---------- Chat ----------
class ChatMessage(BaseModel):
    role: str
    content: str


class ChatCompletionRequest(BaseModel):
    model: str = "qwen"
    messages: list[ChatMessage]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = None
    stream: Optional[bool] = False


# ---------- Images ----------
class ImageGenerationRequest(BaseModel):
    prompt: str
    model: str = "flux"
    n: int = 1
    size: str = "1024x1024"
    negative_prompt: Optional[str] = ""
    steps: Optional[int] = 20
    cfg_scale: Optional[float] = 7.0
    seed: Optional[int] = -1


# ---------- Videos ----------
class VideoRequest(BaseModel):
    prompt: str
    model: str = "wan2.1-1.3b"
    duration: int = 3
    fps: int = 16
    width: int = 832
    height: int = 480
    seed: Optional[int] = None


# ---------- Audio ----------
class AudioSpeechRequest(BaseModel):
    model: str = "kokoro"
    input: str
    voice: str = "af_sarah"
    response_format: Literal["mp3", "wav", "pcm"] = "mp3"
    speed: float = 1.0


class AudioTranscriptionRequest(BaseModel):
    model: str = "whisper-large-v3"
    language: Optional[str] = None
    response_format: str = "json"

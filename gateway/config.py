"""全局配置"""
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    HOST: str = "0.0.0.0"
    PORT: int = 8000
    DEBUG: bool = False

    # API 鉴权
    API_KEY: str = "local-ai-gateway-secret-key"

    # Ollama
    OLLAMA_BASE_URL: str = "http://127.0.0.1:11434/v1"
    OLLAMA_API_KEY: str = "ollama"
    # 文本对话模型（"qwen" 别名指向它）
    OLLAMA_TEXT_MODEL: str = "qwen2.5:7b"
    # 支持视觉的 Ollama 模型（"qwen-vl" 别名指向它）；
    # 本地已有 qwen3.5:9b 等视觉模型时，可在 .env 里改为对应名字，免下 qwen2.5vl
    OLLAMA_VL_MODEL: str = "qwen2.5-vl:7b"

    # SDCPP REST
    SDCPP_URL: str = "http://127.0.0.1:8080"

    # Kokoro TTS
    KOKORO_URL: str = "http://127.0.0.1:8880"

    # faster-whisper ASR
    ASR_URL: str = "http://127.0.0.1:8881"

    # Video worker
    VIDEO_WORKER_URL: str = "http://127.0.0.1:8001"

    # Redis
    REDIS_URL: str = "redis://127.0.0.1:6379/0"

    # Model paths
    MODEL_DIR: str = "/root/.local-ai-models"

    class Config:
        env_file = ".env"


settings = Settings()

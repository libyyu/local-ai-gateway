"""
Local AI Gateway - 统一网关主入口
OpenAI 兼容的本地多模态推理服务
"""
import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from gateway.config import settings
from gateway.routers import (
    chat,
    images,
    videos,
    audio_speech,
    audio_transcribe,
    models as models_router,
)
from gateway.agent import router as agent_router

app = FastAPI(
    title="Local AI Gateway",
    description="OpenAI-compatible unified gateway for local models (text/image/video/audio)",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 挂载路由
app.include_router(chat.router, prefix="/v1", tags=["chat"])
app.include_router(images.router, prefix="/v1", tags=["images"])
app.include_router(videos.router, prefix="/v1", tags=["videos"])
app.include_router(audio_speech.router, prefix="/v1", tags=["audio"])
app.include_router(audio_transcribe.router, prefix="/v1", tags=["audio"])
app.include_router(models_router.router, prefix="/v1", tags=["models"])
app.include_router(agent_router.router, prefix="/v1/agent", tags=["agent"])


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run(
        "gateway.main:app",
        host=settings.HOST,
        port=settings.PORT,
        reload=settings.DEBUG,
    )

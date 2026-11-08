"""
Video Generation Worker
支持 Wan2.1 / CogVideoX / LTX-Video
"""
import os
import uuid
import gc
import uvicorn
import torch
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel

app = FastAPI(title="Video Worker")

MODEL_DIR = os.getenv("MODEL_DIR", "/root/.local-ai-models/video")
OUTPUT_DIR = os.getenv("VIDEO_OUTPUT_DIR", "/tmp/video_output")
os.makedirs(OUTPUT_DIR, exist_ok=True)

# 模型缓存
_pipelines: dict[str, object] = {}


def get_pipeline(model_name: str):
    """懒加载 pipeline"""
    if model_name in _pipelines:
        return _pipelines[model_name]

    dtype = torch.float16 if torch.cuda.is_available() else torch.float32

    if "wan" in model_name:
        from diffusers import WanPipeline
        path = os.path.join(MODEL_DIR, model_name)
        if not os.path.exists(path):
            # fallback to HF
            path = f"Wan-AI/{model_name.replace('-Diffusers', '')}-Diffusers" if "-" not in model_name else path

        _pipelines[model_name] = WanPipeline.from_pretrained(
            path if os.path.exists(path) else f"Wan-AI/Wan2.1-T2V-1.3B-Diffusers",
            torch_dtype=dtype,
        ).to("cuda" if torch.cuda.is_available() else "cpu")

    elif "cogvideo" in model_name:
        from diffusers import CogVideoXPipeline
        path = os.path.join(MODEL_DIR, model_name)
        _pipelines[model_name] = CogVideoXPipeline.from_pretrained(
            path if os.path.exists(path) else "THUDM/CogVideoX-2b",
            torch_dtype=dtype,
        ).to("cuda" if torch.cuda.is_available() else "cpu")

    elif "ltx" in model_name:
        from diffusers import LTXVideoPipeline
        path = os.path.join(MODEL_DIR, model_name)
        _pipelines[model_name] = LTXVideoPipeline.from_pretrained(
            path if os.path.exists(path) else "Lightricks/LTX-Video",
            torch_dtype=dtype,
        ).to("cuda" if torch.cuda.is_available() else "cpu")
    else:
        raise ValueError(f"Unsupported model: {model_name}")

    return _pipelines[model_name]


class VideoGenRequest(BaseModel):
    prompt: str
    model: str = "wan2.1-1.3b"
    duration: int = 3
    fps: int = 16
    width: int = 832
    height: int = 480
    seed: int | None = None
    init_image: str | None = None  # base64, 用于图生视频
    job_id: str | None = None  # 用于进度回传


@app.post("/generate")
async def generate(req: VideoGenRequest):
    pipe = get_pipeline(req.model)

    num_frames = req.duration * req.fps
    generator = torch.Generator("cuda" if torch.cuda.is_available() else "cpu")
    if req.seed:
        generator.manual_seed(req.seed)

    kwargs = {
        "prompt": req.prompt,
        "num_frames": num_frames,
        "height": req.height,
        "width": req.width,
        "generator": generator,
    }

    # 图生视频
    if req.init_image:
        import base64
        from PIL import Image
        import io as io_mod
        img_bytes = base64.b64decode(req.init_image)
        img = Image.open(io_mod.BytesIO(img_bytes)).convert("RGB")
        img = img.resize((req.width, req.height))
        kwargs["image"] = img

    result = pipe(**kwargs).frames

    # 导出视频
    video_id = str(uuid.uuid4())
    video_path = f"{OUTPUT_DIR}/{video_id}.mp4"

    from diffusers.utils import export_to_video
    export_to_video(result, video_path, fps=req.fps)

    # 清理显存
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    gc.collect()

    return {
        "video_id": video_id,
        "video_url": f"/video/{video_id}.mp4",
        "path": video_path,
        "duration": req.duration,
        "fps": req.fps,
    }


@app.get("/video/{video_id}")
async def get_video(video_id: str):
    video_path = f"{OUTPUT_DIR}/{video_id}.mp4"
    if not os.path.exists(video_path):
        return {"error": "Video not found"}, 404
    return FileResponse(video_path, media_type="video/mp4")


@app.get("/health")
async def health():
    return {"status": "ok", "cuda_available": torch.cuda.is_available(),
            "loaded_models": list(_pipelines.keys())}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)

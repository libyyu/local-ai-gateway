"""Images Generation → SDCPP (sd-server)"""
import time

import httpx
from fastapi import APIRouter, Request, Response

from gateway.config import settings

router = APIRouter()

# model 别名 → sd-server recipe + 槽位文件映射（文件 ID 相对模型根目录 .models/sd）
# 新增模型时：把权重按类别子目录放入 .models/sd/，在此登记映射即可
SDCPP_MODEL_MAP = {
    "flux": {
        "recipe": "flux1-schnell",
        "models": {
            "diffusion_model": "diffusion_models/flux1-schnell-Q4_K_S.gguf",
            "clip_l": "text_encoders/clip_l.safetensors",
            "t5xxl": "text_encoders/t5xxl_fp8_e4m3fn.safetensors",
            "vae": "vae/ae.safetensors",
        },
    },
}

DEFAULT_MODEL_KEY = "flux"


async def _ensure_model_loaded(client: httpx.AsyncClient, model_key: str) -> None:
    """确保 sd-server 已加载指定模型；已加载则跳过（幂等）。"""
    cfg = SDCPP_MODEL_MAP.get(model_key)
    if not cfg:
        return  # 未登记映射的模型名，使用当前已加载的模型

    try:
        r = await client.get(f"{settings.SDCPP_URL}/sdcpp/v1/models/status", timeout=10)
        cur = r.json()
        cur_models = cur.get("models", {})
        if cur.get("state") == "ready" and cur.get("recipe") == cfg["recipe"] and all(
            cur_models.get(k) == v for k, v in cfg["models"].items()
        ):
            return
    except Exception:
        pass  # status 查询失败也继续尝试 load

    await client.post(
        f"{settings.SDCPP_URL}/sdcpp/v1/models/load",
        json={"recipe": cfg["recipe"], "models": cfg["models"]},
        timeout=600,
    )


@router.post("/images/generations")
async def images_generations(request: Request):
    """
    OpenAI-compatible: POST /v1/images/generations
    Body: {"prompt": "...", "model": "flux", "n": 1, "size": "1024x1024"}

    sd-server 支持的入参: prompt / n / size("WxH") / output_format / output_compression，
    其余字段（negative_prompt/steps 等）当前被忽略。
    """
    body = await request.json()
    prompt = body.get("prompt", "")
    if not prompt:
        return Response(
            content='{"error": "prompt required"}',
            status_code=400,
            media_type="application/json",
        )

    model_key = body.get("model", DEFAULT_MODEL_KEY)
    payload = {
        "prompt": prompt,
        "n": body.get("n", 1),
        "size": body.get("size", "1024x1024"),
        "output_format": "png",
    }

    async with httpx.AsyncClient(timeout=600) as client:
        try:
            await _ensure_model_loaded(client, model_key)
        except httpx.HTTPError as e:
            return Response(
                content=f'{{"error": "model load failed: {e}"}}',
                status_code=502,
                media_type="application/json",
            )

        resp = await client.post(
            f"{settings.SDCPP_URL}/v1/images/generations",
            json=payload,
        )

        if resp.status_code != 200:
            return Response(
                content=resp.content,
                status_code=resp.status_code,
                media_type="application/json",
            )

        data = resp.json()
        return {
            "created": data.get("created", int(time.time())),
            "data": data.get("data", []),
        }

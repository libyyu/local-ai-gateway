"""
Agent 编排 - qwen 当导演，自动串联 text→image→video→tts
"""
import httpx
import uuid
import time
import asyncio
import json
import re
from fastapi import APIRouter, Request, Response
from pydantic import BaseModel
from typing import Optional

from gateway.config import settings

router = APIRouter()


class AgentRequest(BaseModel):
    """Agent 编排请求"""
    instruction: str                          # 自然语言指令
    mode: str = "full"                        # full | script | storyboard
    # full: 文字→图→视频→配音全流程
    # script: 只生成文案+分镜
    # storyboard: 文案+分镜+配图
    output_dir: Optional[str] = "/tmp/agent_output"
    voice: str = "af_sarah"
    duration_per_clip: int = 3
    num_clips: int = 3


@router.post("/create")
async def create_agent_task(req: AgentRequest):
    """
    创建一个 Agent 编排任务
    POST /v1/agent/create
    """
    job_id = str(uuid.uuid4())

    # 后台执行编排
    asyncio.create_task(_run_agent_pipeline(job_id, req))

    return {
        "job_id": job_id,
        "status": "started",
        "mode": req.mode,
        "instruction": req.instruction,
    }


@router.get("/{job_id}")
async def get_agent_status(job_id: str):
    """查询 Agent 任务状态"""
    # 从 Redis 或内存读取
    try:
        import redis
        r = redis.from_url(settings.REDIS_URL, decode_responses=True)
        data = r.hgetall(f"agent:job:{job_id}")
        if not data:
            return {"error": "Job not found"}, 404
        return {k: v for k, v in data.items()}
    except Exception:
        return {"error": "Redis unavailable"}, 500


async def _run_agent_pipeline(job_id: str, req: AgentRequest):
    """执行完整的 Agent 编排管线"""
    import redis
    r = redis.from_url(settings.REDIS_URL, decode_responses=True)
    REDIS_KEY = f"agent:job:{job_id}"

    def update(state: dict):
        r.hset(REDIS_KEY, mapping={k: str(v) for k, v in state.items()})
        r.expire(REDIS_KEY, 3600 * 24)

    update({
        "status": "running",
        "stage": "script_writing",
        "progress": "0.1",
        "instruction": req.instruction,
    })

    # ========== Stage 1: 让 qwen 生成剧本 + 分镜 ==========
    script_prompt = f"""你是一个短视频导演。请根据用户需求生成分镜脚本。
用户需求: {req.instruction}

请按以下 JSON 格式输出，不要有任何额外文字：
{{
    "title": "视频标题",
    "summary": "一句话概述",
    "scenes": [
        {{
            "scene_id": 1,
            "description": "场景描述（给导演看）",
            "image_prompt": "用于AI生图的英文prompt，详细描述画面内容、风格、光线、构图",
            "video_prompt": "用于AI视频生成的英文prompt，描述画面中物体的运动",
            "narration": "旁白文案",
            "duration": {req.duration_per_clip}
        }}
    ]
}}

生成 {req.num_clips} 个场景，image_prompt 和 video_prompt 必须是英文。"""

    try:
        async with httpx.AsyncClient(timeout=120) as client:
            resp = await client.post(
                f"{settings.OLLAMA_BASE_URL}/chat/completions",
                json={
                    "model": settings.OLLAMA_TEXT_MODEL,
                    "messages": [{"role": "user", "content": script_prompt}],
                    "temperature": 0.8,
                },
                headers={"Authorization": f"Bearer {settings.OLLAMA_API_KEY}"},
            )
            script_text = resp.json()["choices"][0]["message"]["content"]

        # 提取 JSON
        json_match = re.search(r'\{.*\}', script_text, re.DOTALL)
        if json_match:
            script = json.loads(json_match.group())
        else:
            script = {"title": "Generated", "scenes": []}

        update({
            "stage": "script_done",
            "progress": "0.2",
            "script": json.dumps(script, ensure_ascii=False),
        })

    except Exception as e:
        update({"status": "failed", "error": f"Script generation failed: {e}"})
        return

    if req.mode == "script":
        update({"status": "completed", "progress": "1.0", "result": json.dumps(script, ensure_ascii=False)})
        return

    scenes = script.get("scenes", [])
    total = len(scenes)
    results = []

    # ========== Stage 2: 逐场景生图 ==========
    update({"stage": "image_generation", "progress": "0.3"})

    for i, scene in enumerate(scenes):
        try:
            async with httpx.AsyncClient(timeout=300) as client:
                img_resp = await client.post(
                    f"{settings.SDCPP_URL}/txt2img",
                    json={
                        "prompt": scene.get("image_prompt", scene.get("description", "")),
                        "width": 832,
                        "height": 480,
                        "steps": 20,
                        "cfg_scale": 7.0,
                        "checkpoint": "flux-1-schnell-q4_k_m.gguf",
                    },
                )
                img_data = img_resp.json()
                scene["image"] = img_data.get("images", [""])[0]
        except Exception as e:
            scene["image_error"] = str(e)

        progress = 0.3 + (i + 1) / total * 0.2
        update({"progress": str(progress), "current_scene": str(i + 1)})

    if req.mode == "storyboard":
        storyboard = [{
            "scene_id": s.get("scene_id"),
            "description": s.get("description"),
            "narration": s.get("narration"),
            "image": s.get("image", ""),
        } for s in scenes]
        update({"status": "completed", "progress": "1.0",
                "result": json.dumps({"script": script, "storyboard": storyboard}, ensure_ascii=False)})
        return

    # ========== Stage 3: 图生视频 ==========
    update({"stage": "video_generation", "progress": "0.5"})

    for i, scene in enumerate(scenes):
        try:
            async with httpx.AsyncClient(timeout=600) as client:
                vid_resp = await client.post(
                    f"{settings.VIDEO_WORKER_URL}/generate",
                    json={
                        "prompt": scene.get("video_prompt", scene.get("description", "")),
                        "model": "wan2.1-1.3b",
                        "duration": scene.get("duration", req.duration_per_clip),
                        "width": 832,
                        "height": 480,
                        "fps": 16,
                        "init_image": scene.get("image", ""),
                    },
                )
                vid_result = vid_resp.json()
                scene["video_url"] = vid_result.get("video_url", "")
        except Exception as e:
            scene["video_error"] = str(e)

        progress = 0.5 + (i + 1) / total * 0.3
        update({"progress": str(progress)})

    # ========== Stage 4: TTS 配音 ==========
    update({"stage": "tts", "progress": "0.8"})

    for i, scene in enumerate(scenes):
        narration = scene.get("narration", "")
        if narration:
            try:
                async with httpx.AsyncClient(timeout=60) as client:
                    tts_resp = await client.post(
                        f"{settings.KOKORO_URL}/v1/audio/speech",
                        json={
                            "model": "kokoro",
                            "input": narration,
                            "voice": req.voice,
                            "response_format": "mp3",
                        },
                    )
                    scene["audio"] = tts_resp.content.hex()  # base64 in redis
            except Exception as e:
                scene["audio_error"] = str(e)

        progress = 0.8 + (i + 1) / total * 0.15
        update({"progress": str(progress)})

    # ========== Stage 5: 汇总 ==========
    final_result = {
        "title": script.get("title"),
        "summary": script.get("summary"),
        "scenes": [
            {
                "scene_id": s.get("scene_id"),
                "description": s.get("description"),
                "narration": s.get("narration"),
                "image": s.get("image", ""),
                "video_url": s.get("video_url", ""),
                "has_audio": "audio" in s,
            } for s in scenes
        ],
    }

    update({
        "status": "completed",
        "progress": "1.0",
        "result": json.dumps(final_result, ensure_ascii=False),
    })

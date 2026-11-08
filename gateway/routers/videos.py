"""Videos → Video Worker (Redis-backed async jobs)"""
import uuid
import time
import asyncio
import httpx
from fastapi import APIRouter, Request
from sse_starlette.sse import EventSourceResponse

from gateway.config import settings

router = APIRouter()

# 尝试导入 Redis
try:
    import redis
    r = redis.from_url(settings.REDIS_URL, decode_responses=True)
    REDIS_AVAILABLE = True
except Exception:
    REDIS_AVAILABLE = False
    print("[WARN] Redis not available, using in-memory store")


def _store_job(job_id: str, data: dict):
    if REDIS_AVAILABLE:
        r.hset(f"video:job:{job_id}", mapping={k: str(v) for k, v in data.items()})
        r.expire(f"video:job:{job_id}", 3600 * 24)  # 24h TTL
    else:
        # fallback: in-memory
        pass


def _get_job(job_id: str) -> dict | None:
    if REDIS_AVAILABLE:
        data = r.hgetall(f"video:job:{job_id}")
        return data if data else None
    return None


@router.post("/videos")
async def create_video(request: Request):
    """
    POST /v1/videos
    Body: {"prompt": "...", "model": "wan2.1-1.3b", "duration": 3, "fps": 16, "width": 832, "height": 480}
    Returns: {"id": "...", "status": "queued"}
    """
    body = await request.json()
    job_id = str(uuid.uuid4())

    job_data = {
        "id": job_id,
        "status": "queued",
        "progress": "0.0",
        "result_url": "",
        "error": "",
        "request": str(body),
        "created_at": str(int(time.time())),
    }
    _store_job(job_id, job_data)

    # 提交到 video worker
    asyncio.create_task(_submit_video_job(job_id, body))

    return {"id": job_id, "status": "queued", "created_at": job_data["created_at"]}


@router.get("/videos/{job_id}")
async def get_video_job(job_id: str):
    """GET /v1/videos/{id} → 查询任务状态"""
    data = _get_job(job_id)
    if not data:
        return {"error": "Job not found"}, 404

    return {
        "id": data.get("id"),
        "status": data.get("status"),
        "progress": float(data.get("progress", 0)),
        "result_url": data.get("result_url") or None,
        "error": data.get("error") or None,
        "created_at": data.get("created_at"),
    }


@router.get("/videos/{job_id}/stream")
async def stream_video_progress(job_id: str):
    """SSE 实时推送进度"""
    async def event_generator():
        last_progress = -1
        while True:
            data = _get_job(job_id)
            if not data:
                yield {"event": "error", "data": "Job not found"}
                break

            progress = float(data.get("progress", 0))
            status = data.get("status", "queued")

            if progress != last_progress or status in ("completed", "failed"):
                yield {
                    "event": "progress",
                    "data": str({
                        "status": status,
                        "progress": progress,
                        "result_url": data.get("result_url"),
                        "error": data.get("error"),
                    }),
                }
                last_progress = progress

            if status == "completed":
                yield {"event": "complete", "data": data.get("result_url", "")}
                break
            if status == "failed":
                yield {"event": "error", "data": data.get("error", "Unknown error")}
                break

            await asyncio.sleep(1)

    return EventSourceResponse(event_generator())


async def _submit_video_job(job_id: str, req: dict):
    """后台提交到 video worker"""
    _store_job(job_id, {"status": "processing", "progress": "0.05"})

    try:
        async with httpx.AsyncClient(timeout=600) as client:
            resp = await client.post(
                f"{settings.VIDEO_WORKER_URL}/generate",
                json={**req, "job_id": job_id},
            )
            result = resp.json()

            _store_job(job_id, {
                "status": "completed",
                "progress": "1.0",
                "result_url": result.get("video_url", ""),
            })
    except Exception as e:
        _store_job(job_id, {"status": "failed", "error": str(e)})

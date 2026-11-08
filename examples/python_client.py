"""
Local AI Gateway - Python 客户端示例
兼容 OpenAI SDK
"""
from openai import OpenAI

# 指向本地网关
client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="local-ai-gateway-secret-key",
)


def demo_chat():
    """文本对话"""
    resp = client.chat.completions.create(
        model="qwen",
        messages=[{"role": "user", "content": "用一句话描述赛博朋克城市的黄昏"}],
    )
    print("Chat:", resp.choices[0].message.content)
    return resp.choices[0].message.content


def demo_image(prompt: str):
    """生图"""
    img = client.images.generate(
        model="flux",
        prompt=prompt,
        size="1024x1024",
        n=1,
    )
    print("Image generated, b64 length:", len(img.data[0].b64_json or ""))
    # 保存
    import base64
    if img.data[0].b64_json:
        with open("/tmp/gen.png", "wb") as f:
            f.write(base64.b64decode(img.data[0].b64_json))
        print("Saved: /tmp/gen.png")


def demo_tts(text: str):
    """TTS 配音"""
    speech = client.audio.speech.create(
        model="kokoro",
        input=text,
        voice="af_sarah",
    )
    speech.stream_to_file("/tmp/output.mp3")
    print("Saved: /tmp/output.mp3")


def demo_video(prompt: str):
    """视频生成（异步）"""
    import httpx
    resp = httpx.post(
        "http://localhost:8000/v1/videos",
        json={"prompt": prompt, "model": "wan2.1-1.3b", "duration": 3},
        headers={"Authorization": "Bearer local-ai-gateway-secret-key"},
    ).json()
    print(f"Job created: {resp['id']}")

    # 轮询
    job_id = resp["id"]
    for _ in range(60):
        status = httpx.get(
            f"http://localhost:8000/v1/videos/{job_id}",
            headers={"Authorization": "Bearer local-ai-gateway-secret-key"},
        ).json()
        print(f"  status: {status['status']}, progress: {status.get('progress', 0)}")
        if status["status"] == "completed":
            print(f"Video URL: {status['result_url']}")
            break
        elif status["status"] == "failed":
            print(f"Error: {status.get('error')}")
            break
        import time
        time.sleep(5)


def demo_agent(instruction: str):
    """Agent 编排 - 全自动"""
    import httpx, time
    resp = httpx.post(
        "http://localhost:8000/v1/agent/create",
        json={
            "instruction": instruction,
            "mode": "full",
            "num_clips": 3,
            "duration_per_clip": 3,
            "voice": "af_sarah",
        },
        headers={"Authorization": "Bearer local-ai-gateway-secret-key"},
    ).json()
    job_id = resp["job_id"]
    print(f"Agent job: {job_id}")

    for _ in range(120):
        status = httpx.get(
            f"http://localhost:8000/v1/agent/{job_id}",
            headers={"Authorization": "Bearer local-ai-gateway-secret-key"},
        ).json()
        print(f"  stage: {status.get('stage', '?')}, progress: {status.get('progress', 0)}")
        if status.get("status") in ("completed", "failed"):
            if status.get("result"):
                import json
                result = json.loads(status["result"])
                print(f"\n✅ Done! Title: {result.get('title')}")
                for s in result.get("scenes", []):
                    print(f"  Scene {s['scene_id']}: video={s.get('video_url', 'N/A')}")
            else:
                print(f"  Error: {status.get('error')}")
            break
        time.sleep(5)


if __name__ == "__main__":
    # 逐个测试
    prompt = demo_chat()
    demo_image(prompt)
    demo_tts(prompt)
    demo_video(prompt)
    # demo_agent("做一个30秒的赛博朋克城市宣传短片")  # 全流程（耗时较长）

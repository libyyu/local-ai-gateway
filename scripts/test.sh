#!/usr/bin/env bash
# 测试所有接口
set -e

cd "$(dirname "$0")/.."
source venv/bin/activate

API_KEY="${API_KEY:-local-ai-gateway-secret-key}"
BASE="http://localhost:8000/v1"
AUTH="Authorization: Bearer $API_KEY"

echo "🧪 Testing Local AI Gateway..."
echo "   Base: $BASE"
echo ""

# 1. Health
echo "▶ [1] Health check..."
curl -s http://localhost:8000/health | jq .
echo ""

# 2. Models
echo "▶ [2] List models..."
curl -s -H "$AUTH" "$BASE/models" | jq .
echo ""

# 3. Chat
echo "▶ [3] Chat completion..."
curl -s -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"Say hi in one sentence"}]}' \
    "$BASE/chat/completions" | jq -r '.choices[0].message.content'
echo ""

# 4. Images
echo "▶ [4] Image generation..."
curl -s -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"prompt":"a cute cat sitting on a moon","model":"flux","size":"512x512"}' \
    "$BASE/images/generations" | jq '.data[0] | has("b64_json")'
echo ""

# 5. TTS
echo "▶ [5] TTS..."
curl -s -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"model":"kokoro","input":"Hello world","voice":"af_sarah","response_format":"mp3"}' \
    "$BASE/audio/speech" -o /tmp/test_tts.mp3
echo "   Saved: /tmp/test_tts.mp3 ($(wc -c < /tmp/test_tts.mp3) bytes)"
echo ""

# 6. Video (async)
echo "▶ [6] Video generation (async)..."
VIDEO_RESP=$(curl -s -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"prompt":"a bird flying over the ocean","model":"wan2.1-1.3b","duration":2}' \
    "$BASE/videos")
echo "$VIDEO_RESP" | jq .
JOB_ID=$(echo "$VIDEO_RESP" | jq -r '.id')
echo ""
echo "   Polling job $JOB_ID ..."
for i in $(seq 1 30); do
    STATUS=$(curl -s -H "$AUTH" "$BASE/videos/$JOB_ID" | jq -r '.status')
    echo "   [$i] status: $STATUS"
    if [ "$STATUS" = "completed" ] || [ "$STATUS" = "failed" ]; then
        break
    fi
    sleep 5
done
echo ""

echo "✅ All tests done!"

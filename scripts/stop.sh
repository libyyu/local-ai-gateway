#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."

echo "🛑 Stopping Local AI Gateway..."

# 停止所有服务
for svc in gateway video_worker asr kokoro sdcpp; do
    pidfile="/tmp/${svc}.pid"
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && echo "   Stopped $svc (PID: $pid)"
        fi
        rm -f "$pidfile"
    fi
done

# 也尝试 docker 停止
docker stop sdcpp 2>/dev/null || true

echo "✅ All services stopped"

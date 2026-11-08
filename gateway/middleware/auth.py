"""API Key 鉴权中间件"""
from fastapi import Request, Response
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from gateway.config import settings


class AuthMiddleware(BaseHTTPMiddleware):
    """全局 API Key 校验中间件"""

    EXEMPT_PATHS = {"/health", "/docs", "/openapi.json", "/redoc"}

    async def dispatch(self, request: Request, call_next) -> Response:
        # 免鉴权路径
        if request.url.path in self.EXEMPT_PATHS:
            return await call_next(request)

        # 文档页面也放行
        if request.url.path.startswith(("/docs", "/redoc")):
            return await call_next(request)

        # 校验 API Key
        api_key = request.headers.get("Authorization", "")
        expected = f"Bearer {settings.API_KEY}"

        if not api_key or api_key != expected:
            return JSONResponse(
                status_code=401,
                content={"error": {"message": "Invalid API key", "type": "invalid_request_error"}},
            )

        return await call_next(request)

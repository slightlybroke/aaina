from starlette.exceptions import HTTPException
from starlette.responses import JSONResponse


class UploadLimit:
    """Bound the full multipart body, including requests without Content-Length."""

    def __init__(self, app, maximum=10_100_000):
        self.app, self.maximum = app, maximum

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST":
            return await self.app(scope, receive, send)
        headers = dict(scope["headers"])
        length = headers.get(b"content-length", b"0")
        if not length.isdigit() or int(length) > self.maximum:
            return await JSONResponse({"detail": "Upload too large."}, status_code=413)(
                scope, receive, send
            )
        received = 0

        async def limited_receive():
            nonlocal received
            message = await receive()
            received += len(message.get("body", b""))
            if received > self.maximum:
                raise HTTPException(413, "Upload too large.")
            return message

        await self.app(scope, limited_receive, send)

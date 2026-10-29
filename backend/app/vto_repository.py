"""Use the existing HTTP/ownership adapter, with a separate private bucket and table."""

from urllib.parse import quote


class VtoRepository:
    def __init__(self, repo):
        self.repo = repo

    async def owned(self, user, **filters):
        return await self.repo.owned("vto_jobs", user, **filters)

    async def insert(self, job):
        response = await self.repo.request(
            "POST",
            "/rest/v1/vto_jobs",
            params={"on_conflict": "user_id,idempotency_key"},
            json=job,
            headers={"Prefer": "resolution=ignore-duplicates,return=representation"},
        )
        return response.json()

    async def patch(self, job_id, values, **filters):
        response = await self.repo.request(
            "PATCH",
            "/rest/v1/vto_jobs",
            params={"id": f"eq.{job_id}", **filters},
            json=values,
            headers={"Prefer": "return=representation"},
        )
        return response.json()

    async def rows(self, **filters):
        return await self.repo.rows("vto_jobs", **filters)

    async def rpc(self, name, payload=None):
        return await self.repo.rpc(name, payload)

    def path(self, path):
        return "/storage/v1/object/vto-images/" + quote(path, safe="/")

    async def upload(self, path, content):
        await self.repo.request(
            "POST",
            self.path(path),
            content=content,
            headers={"Content-Type": "image/jpeg", "x-upsert": "false"},
        )

    async def download(self, path):
        return (await self.repo.request("GET", self.path(path))).content

    async def delete(self, path):
        await self.repo.request(
            "DELETE", "/storage/v1/object/vto-images", json={"prefixes": [path]}
        )

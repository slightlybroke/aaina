from urllib.parse import quote

import httpx


class Supabase:
    """Privileged adapter. Every user-facing lookup includes the verified owner."""

    def __init__(self, settings, client: httpx.AsyncClient):
        self.s, self.client = settings, client

    async def request(self, method, path, **kwargs):
        response = await self.client.request(
            method,
            self.s.supabase_url + path,
            headers={
                "apikey": self.s.supabase_service_role_key,
                "Authorization": f"Bearer {self.s.supabase_service_role_key}",
                **kwargs.pop("headers", {}),
            },
            timeout=25,
            **kwargs,
        )
        response.raise_for_status()
        return response

    async def rows(self, table, **params):
        return (await self.request("GET", f"/rest/v1/{table}", params=params)).json()

    async def owned(self, table, user_id, **filters):
        return await self.rows(table, user_id=f"eq.{user_id}", **filters)

    async def request_account_deletion(self, user_id):
        await self.request(
            "POST",
            "/rest/v1/account_deletion_requests",
            params={"on_conflict": "user_id"},
            json={"user_id": user_id},
            headers={"Prefer": "resolution=ignore-duplicates,return=minimal"},
        )

    async def insert_job(self, job):
        response = await self.request(
            "POST",
            "/rest/v1/analysis_jobs",
            params={"on_conflict": "user_id,idempotency_key"},
            json=job,
            headers={"Prefer": "resolution=ignore-duplicates,return=representation"},
        )
        return response.json()

    async def patch(self, job_id, values, **filters):
        response = await self.request(
            "PATCH",
            "/rest/v1/analysis_jobs",
            params={"id": f"eq.{job_id}", **filters},
            json=values,
            headers={"Prefer": "return=representation"},
        )
        return response.json()

    async def rpc(self, name, payload=None):
        response = await self.request("POST", f"/rest/v1/rpc/{name}", json=payload or {})
        return response.json() if response.content else None

    def object_path(self, path):
        return f"/storage/v1/object/{self.s.storage_bucket}/{quote(path, safe='/')}"

    async def upload(self, path, content):
        await self.request(
            "POST",
            self.object_path(path),
            content=content,
            headers={"Content-Type": "image/jpeg", "x-upsert": "false"},
        )

    async def download(self, path):
        return (await self.request("GET", self.object_path(path))).content

    async def delete(self, path):
        # Batch remove is idempotent even when the object has already disappeared.
        await self.request(
            "DELETE", f"/storage/v1/object/{self.s.storage_bucket}", json={"prefixes": [path]}
        )

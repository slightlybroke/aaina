from copy import deepcopy

import httpx


class MemoryRepository:
    """Test double only; production always uses Supabase."""

    def __init__(self):
        self.jobs, self.analyses, self.objects = {}, [], {}
        self.uploads = 0
        self.delete_fails = False

    async def owned(self, table, user_id, **filters):
        rows = list(self.jobs.values()) if table == "analysis_jobs" else self.analyses
        return deepcopy(
            [
                row
                for row in rows
                if row["user_id"] == user_id
                and all(row.get(k) == v[3:] for k, v in filters.items() if v.startswith("eq."))
            ]
        )

    async def insert_job(self, job):
        if any(
            j["user_id"] == job["user_id"] and j["idempotency_key"] == job["idempotency_key"]
            for j in self.jobs.values()
        ):
            return []
        self.jobs[job["id"]] = {**job, "cleanup_status": "pending", "cleanup_attempts": 0}
        return [deepcopy(self.jobs[job["id"]])]

    async def patch(self, job_id, values, **filters):
        row = self.jobs[job_id]
        for k, v in filters.items():
            if v.startswith("eq.") and str(row.get(k)) != v[3:]:
                return []
        row.update(values)
        return [deepcopy(row)]

    async def upload(self, path, content):
        self.uploads += 1
        self.objects[path] = content

    async def download(self, path):
        return self.objects[path]

    async def delete(self, path):
        if self.delete_fails:
            raise httpx.ConnectError("mock storage failure")
        self.objects.pop(path, None)

    async def rows(self, table, **filters):
        return deepcopy(
            [row for row in self.jobs.values() if row.get("cleanup_status") != "deleted"]
        )

    async def rpc(self, name, payload=None):
        if name == "complete_analysis_job":
            row = self.jobs[payload["p_job"]]
            if row["status"] != "processing" or row["lease_token"] != payload["p_token"]:
                return False
            self.analyses.append(
                {
                    "job_id": row["id"],
                    "user_id": row["user_id"],
                    "overall_score": payload["p_score"],
                    "metrics": payload["p_metrics"],
                }
            )
            row["status"] = "completed"
            return True
        raise AssertionError(name)

import logging

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

# HTTPX INFO logs include signed request URLs. Keep them out of application logs.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logging.getLogger("websockets").setLevel(logging.WARNING)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", hide_input_in_errors=True)
    supabase_url: str
    supabase_publishable_key: str
    supabase_service_role_key: str
    youcam_api_key: str
    youcam_vto_enabled: bool = False
    gemini_api_key: SecretStr = SecretStr("")
    gemini_model: str = Field(default="gemini-3.5-flash-lite", pattern=r"^[a-z0-9][a-z0-9.-]{1,79}$")
    gemini_live_model: str = Field(default="gemini-3.8-live", pattern=r"^[a-z0-9][a-z0-9.-]{1,79}$")
    gemini_live_session_seconds: int = Field(default=300, ge=30, le=600)
    youcam_base_url: str = "https://yce-api-01.makeupar.com"
    storage_bucket: str = "analysis-incoming"
    cors_origins: list[str] = ["http://localhost:3000"]
    youcam_asset_hosts: list[str] = ["yce-us.s3-accelerate.amazonaws.com"]
    poll_seconds: int = Field(default=10, ge=10, le=300)
    job_timeout_seconds: int = Field(default=1800, ge=60, le=3600)
    image_ttl_seconds: int = Field(default=3600, ge=60, le=3600)

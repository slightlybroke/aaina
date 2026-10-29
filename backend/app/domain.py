from datetime import UTC, datetime

TERMINAL = {"completed", "failed", "expired"}
TRANSITIONS = {
    "uploading": {"pending", "failed", "expired"},
    "pending": {"submitting", "failed", "expired"},
    "submitting": {"processing", "failed", "expired"},
    "processing": {"completed", "failed", "expired"},
}


def utcnow():
    return datetime.now(UTC)


def transition(current: str, target: str):
    if target not in TRANSITIONS.get(current, set()):
        raise ValueError(f"Invalid transition: {current} -> {target}")


class ContractError(ValueError):
    pass


class ProviderError(Exception):
    def __init__(self, code: str, retryable: bool = False):
        self.code = code
        self.retryable = retryable
        super().__init__(code)

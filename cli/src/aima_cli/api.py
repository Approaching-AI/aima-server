from __future__ import annotations

import json
from typing import Any, Optional

import httpx


class AIMAApiError(RuntimeError):
    def __init__(self, status_code: int, detail: str, payload: Any = None) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail
        self.payload = payload


class DeviceApiClient:
    def __init__(
        self,
        *,
        platform_url: str,
        client: Optional[httpx.AsyncClient] = None,
    ) -> None:
        self.platform_url = platform_url.rstrip("/")
        self.api_base_url = f"{self.platform_url}/api/v1"
        self._client = client
        self._owns_client = client is None

    async def __aenter__(self) -> "DeviceApiClient":
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=self.platform_url,
                timeout=30.0,
                trust_env=False,
            )
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        if self._owns_client and self._client is not None:
            await self._client.aclose()

    @property
    def client(self) -> httpx.AsyncClient:
        if self._client is None:
            raise RuntimeError("DeviceApiClient must be used inside an async context manager")
        return self._client

    async def _request(
        self,
        method: str,
        path: str,
        *,
        headers: Optional[dict[str, str]] = None,
        json_body: Any = None,
        params: Optional[dict[str, Any]] = None,
    ) -> Any:
        response = await self.client.request(
            method,
            path,
            headers=headers,
            json=json_body,
            params=params,
        )
        if response.status_code >= 400:
            detail = response.text
            payload = None
            try:
                payload = response.json()
                if isinstance(payload, dict) and "detail" in payload:
                    detail_value = payload["detail"]
                    if isinstance(detail_value, str):
                        detail = detail_value
                    else:
                        detail = json.dumps(detail_value, ensure_ascii=False)
            except Exception:
                payload = None
            raise AIMAApiError(response.status_code, detail, payload=payload)

        if not response.content:
            return {}
        try:
            return response.json()
        except Exception:
            return response.text

    @staticmethod
    def device_headers(device_token: str) -> dict[str, str]:
        return {"Authorization": f"Bearer {device_token}"}

    async def fetch_go_manifest(
        self,
        *,
        schema_version: str = "v1",
        referral_code: str = "",
        worker_code: str = "",
    ) -> dict[str, Any]:
        params = {"schema_version": schema_version}
        if referral_code:
            params["ref"] = referral_code
        if worker_code:
            params["worker_code"] = worker_code
        return await self._request("GET", "/api/v1/ux-manifests/device-go", params=params)

    async def self_register(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._request("POST", "/api/v1/devices/self-register", json_body=payload)

    async def poll_device_flow(self, *, device_code: str) -> dict[str, Any]:
        return await self._request("GET", f"/api/v1/device-flows/{device_code}/poll")

    async def get_active_task(self, *, device_id: str, device_token: str) -> dict[str, Any]:
        return await self._request(
            "GET",
            f"/api/v1/devices/{device_id}/active-task",
            headers=self.device_headers(device_token),
        )

    async def create_task(
        self,
        *,
        device_id: str,
        device_token: str,
        description: str,
        intake: dict[str, Any] | None = None,
        experience_search: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"description": description}
        if intake:
            payload["intake"] = intake
        if experience_search:
            payload["experience_search"] = experience_search
        return await self._request(
            "POST",
            f"/api/v1/devices/{device_id}/tasks",
            headers=self.device_headers(device_token),
            json_body=payload,
        )

    async def cancel_task(self, *, device_id: str, device_token: str, task_id: str) -> dict[str, Any]:
        return await self._request(
            "POST",
            f"/api/v1/devices/{device_id}/tasks/{task_id}/cancel",
            headers=self.device_headers(device_token),
        )

    async def poll(self, *, device_id: str, device_token: str, wait: int) -> dict[str, Any]:
        return await self._request(
            "GET",
            f"/api/v1/devices/{device_id}/poll",
            headers=self.device_headers(device_token),
            params={"wait": wait},
        )

    async def submit_result(
        self,
        *,
        device_id: str,
        device_token: str,
        command_id: str,
        exit_code: int,
        stdout: str,
        stderr: str,
        result_id: str,
    ) -> dict[str, Any]:
        return await self._request(
            "POST",
            f"/api/v1/devices/{device_id}/result",
            headers=self.device_headers(device_token),
            json_body={
                "command_id": command_id,
                "exit_code": exit_code,
                "stdout": stdout,
                "stderr": stderr,
                "result_id": result_id,
            },
        )

    async def submit_progress(
        self,
        *,
        device_id: str,
        device_token: str,
        command_id: str,
        stdout: str,
        stderr: str,
        message: str,
    ) -> dict[str, Any]:
        return await self._request(
            "POST",
            f"/api/v1/devices/{device_id}/commands/{command_id}/progress",
            headers=self.device_headers(device_token),
            json_body={
                "stdout": stdout,
                "stderr": stderr,
                "message": message,
            },
        )

    async def respond_interaction(
        self,
        *,
        device_id: str,
        device_token: str,
        interaction_id: str,
        answer: str,
    ) -> dict[str, Any]:
        return await self._request(
            "POST",
            f"/api/v1/devices/{device_id}/interactions/{interaction_id}/respond",
            headers=self.device_headers(device_token),
            json_body={"answer": answer},
        )

    async def submit_feedback(
        self,
        *,
        device_id: str,
        device_token: str,
        feedback_type: str,
        description: str,
        os_profile: dict[str, Any],
        task_id: str = "",
    ) -> dict[str, Any]:
        context: dict[str, Any] = {"script_version": "aima-cli/0.1.0"}
        if task_id:
            context["task_id"] = task_id
        payload: dict[str, Any] = {
            "type": feedback_type,
            "environment": os_profile,
            "context": context,
        }
        if description:
            payload["description"] = description
        return await self._request(
            "POST",
            f"/api/v1/devices/{device_id}/feedback",
            headers=self.device_headers(device_token),
            json_body=payload,
        )

    async def mark_offline(self, *, device_id: str, device_token: str) -> dict[str, Any]:
        return await self._request(
            "POST",
            f"/api/v1/devices/{device_id}/offline",
            headers=self.device_headers(device_token),
        )

    async def update_language(
        self,
        *,
        device_id: str,
        device_token: str,
        display_language: str,
    ) -> dict[str, Any]:
        return await self._request(
            "POST",
            f"/api/v1/devices/{device_id}/language",
            headers=self.device_headers(device_token),
            json_body={"display_language": display_language},
        )

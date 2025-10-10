# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

import json
import pickle
import base64
import copy
from typing import Dict, List

from azure.core import MatchConditions
from azure.core.exceptions import (
    HttpResponseError,
    ResourceExistsError,
    ResourceNotFoundError,
)
from azure.storage.blob.aio import (
    BlobServiceClient,
    BlobClient,
    StorageStreamDownloader,
)

try:
    from microsoft_agents.hosting.core.storage.storage import Storage
    from microsoft_agents.hosting.core.storage.store_item import StoreItem
except ImportError:  # pragma: no cover
    from microsoft.agents.hosting.core.storage.storage import Storage
    from microsoft.agents.hosting.core.storage.store_item import StoreItem


def _filter_sensitive_data(data):
    """Recursively filter sensitive information from stored data so it can be logged safely."""
    if data is None:
        return None

    filtered_data = copy.deepcopy(data)

    def _filter_recursive(obj, path=""):
        if isinstance(obj, dict):
            for key, value in obj.items():
                key_lower = key.lower()
                if any(
                    sensitive in key_lower
                    for sensitive in (
                        "token",
                        "password",
                        "secret",
                        "key",
                        "auth",
                        "credential",
                        "access_token",
                        "refresh_token",
                        "graph_access_token",
                        "authorization",
                        "bearer",
                    )
                ):
                    obj[key] = "[FILTERED]"
                elif isinstance(value, str) and (
                    value.startswith("eyJ")
                    or (len(value) > 50 and any(c in value for c in (".", "-", "_")))
                    or value.startswith("1.A")
                ):
                    obj[key] = "[FILTERED]"
                else:
                    _filter_recursive(value, f"{path}.{key}" if path else key)
        elif isinstance(obj, list):
            for index, item in enumerate(obj):
                _filter_recursive(item, f"{path}[{index}]")

    _filter_recursive(filtered_data)
    return filtered_data


class AgentStorageSetting:
    """Azure Blob Storage settings wrapper for the Microsoft 365 Agents SDK."""

    def __init__(self, container_name: str, account_url: str = "", credential=None):
        if not container_name:
            raise ValueError("container_name is required")
        self.container_name = container_name
        self.account_url = account_url
        self.credential = credential


class BlobStorage(Storage):
    """Azure Blob backed storage provider compatible with the Microsoft 365 Agents SDK."""

    def __init__(self, settings: AgentStorageSetting):
        if not settings.container_name:
            raise Exception("Container name is required.")

        if settings.credential:
            blob_service_client = BlobServiceClient(
                account_url=settings.account_url,
                credential=settings.credential,
            )
        else:
            blob_service_client = BlobServiceClient(account_url=settings.account_url)

        self._container_client = blob_service_client.get_container_client(
            settings.container_name
        )
        self._initialized = False

    async def _initialize(self):
        if not self._initialized:
            try:
                await self._container_client.create_container()
            except ResourceExistsError:
                pass
            self._initialized = True
        return self._initialized

    async def read(self, keys: List[str], *, target_cls=None, **_: object) -> Dict[str, object]:
        if not keys:
            raise Exception("Keys are required when reading")

        await self._initialize()
        items: Dict[str, object] = {}

        for key in keys:
            blob_client = self._container_client.get_blob_client(key)
            try:
                item = await self._inner_read_blob(blob_client)
                filtered_item = _filter_sensitive_data(item)
                print(
                    f"DEBUG: Successfully read blob for key '{key}': {type(item)} with data: {filtered_item}"
                )

                if target_cls and isinstance(item, dict):
                    try:
                        if hasattr(target_cls, "from_json_to_store_item"):
                            candidate_item = dict(item)
                            if target_cls.__name__ == "CachedAgentState":
                                cached_hash = candidate_item.get("hash")
                                if cached_hash and "CachedAgentState._hash" not in candidate_item:
                                    candidate_item["CachedAgentState._hash"] = cached_hash
                                state_snapshot = candidate_item.get("state")
                                if isinstance(state_snapshot, dict) and cached_hash:
                                    state_snapshot.setdefault("CachedAgentState._hash", cached_hash)
                            items[key] = target_cls.from_json_to_store_item(candidate_item)
                        elif target_cls.__name__ == "CachedAgentState":
                            if "state" in item and "hash" in item:
                                state_snapshot = item["state"]
                                state_snapshot["CachedAgentState._hash"] = item["hash"]
                                instance = target_cls(state_snapshot)
                                if hasattr(instance, "e_tag") and "e_tag" in item:
                                    instance.e_tag = item["e_tag"]
                                items[key] = instance
                            else:
                                items[key] = item
                        else:
                            instance = target_cls(item)
                            items[key] = instance
                    except Exception as error:
                        print(
                            f"DEBUG: Error creating {target_cls.__name__} instance: {error}. Returning raw item."
                        )
                        items[key] = item
                else:
                    items[key] = item
            except HttpResponseError as err:
                if err.status_code == 404:
                    print(f"DEBUG: Blob not found for key '{key}' (404)")
                    continue
                raise

        print(f"DEBUG: BlobStorage.read() returning {len(items)} items: {list(items.keys())}")
        return items

    async def write(self, changes: Dict[str, StoreItem]):
        if changes is None:
            raise Exception("Changes are required when writing")
        if not changes:
            return

        print(
            f"DEBUG: BlobStorage.write() called with {len(changes)} changes: {list(changes.keys())}"
        )
        for key, item in changes.items():
            filtered_item = _filter_sensitive_data(item)
            print(f"DEBUG: Writing key '{key}': {type(item)} with content: {filtered_item}")

        await self._initialize()

        for name, item in changes.items():
            blob_reference = self._container_client.get_blob_client(name)

            if isinstance(item, dict):
                e_tag = item.get("e_tag")
            elif hasattr(item, "e_tag"):
                e_tag = item.e_tag
            else:
                e_tag = None

            e_tag = None if e_tag == "*" else e_tag
            if e_tag == "":
                raise Exception("blob_storage.write(): etag missing")

            item_str = self._store_item_to_str(item)

            try:
                if e_tag:
                    await blob_reference.upload_blob(
                        item_str,
                        match_condition=MatchConditions.IfNotModified,
                        etag=e_tag,
                    )
                else:
                    await blob_reference.upload_blob(item_str, overwrite=True)
                print(f"DEBUG: Successfully wrote blob for key '{name}'")
            except Exception as error:
                print(f"DEBUG: Error writing blob for key '{name}': {error}")
                raise

    async def delete(self, keys: List[str]):
        if keys is None:
            raise Exception("BlobStorage.delete: keys parameter can't be null")

        await self._initialize()

        for key in keys:
            blob_client = self._container_client.get_blob_client(key)
            try:
                await blob_client.delete_blob()
            except ResourceNotFoundError:
                pass

    def _store_item_to_str(self, item: object) -> str:
        def json_serializer(obj):
            if hasattr(obj, "isoformat"):
                return obj.isoformat()
            if hasattr(obj, "__dict__"):
                return obj.__dict__
            return str(obj)

        try:
            if hasattr(item, "__dict__"):
                item_dict = item.__dict__.copy()
                return json.dumps(item_dict, default=json_serializer)
            return json.dumps(item, default=json_serializer)
        except (TypeError, ValueError):
            pickled_data = pickle.dumps(item)
            encoded_data = base64.b64encode(pickled_data).decode("utf-8")
            return json.dumps({"__pickled__": encoded_data})

    async def _inner_read_blob(self, blob_client: BlobClient):
        blob = await blob_client.download_blob()
        return await self._blob_to_store_item(blob)

    @staticmethod
    async def _blob_to_store_item(blob: StorageStreamDownloader) -> object:
        content = await blob.content_as_text()
        item = json.loads(content)

        if isinstance(item, dict):
            item["e_tag"] = blob.properties.etag.replace('"', "")
            if "__pickled__" in item:
                encoded_data = item["__pickled__"]
                pickled_data = base64.b64decode(encoded_data.encode("utf-8"))
                result = pickle.loads(pickled_data)
                if hasattr(result, "__dict__"):
                    result.e_tag = blob.properties.etag.replace('"', "")
                return result

        return item


# Backward compatibility alias for legacy imports
TABBlobStorageSettings = AgentStorageSetting

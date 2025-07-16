# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

import json
import pickle
import base64
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
# Using Microsoft 365 Agents SDK storage interface
from microsoft.agents.storage.storage import Storage


class TABBlobStorageSettings:
    """The class for Azure Blob configuration for the Microsoft 365 Agents SDK.

    :param container_name: Name of the Blob container.
    :type container_name: str
    :param account_url: URL of the Blob Storage account.
    :type account_url: str
    :param credential: Azure credential for authentication.
    :type credential: Any
    """
        
    def __init__(
        self,
        container_name: str,
        account_url: str = "",
        credential = None,
    ):
        self.container_name = container_name
        self.account_url = account_url
        self.credential = credential

class BlobStorage(Storage):
    """An Azure Blob based storage provider for a bot.

    This class uses a single Azure Storage Blob Container.
    Each entity or StoreItem is serialized into a JSON string and stored in an individual text blob.
    Each blob is named after the store item key,  which is encoded so that it conforms a valid blob name.
    If an entity is an StoreItem, the storage object will set the entity's e_tag
    property value to the blob's e_tag upon read. Afterward, an match_condition with the ETag value
    will be generated during Write. New entities start with a null e_tag.

    :param settings: Settings used to instantiate the Blob service.
    :type settings: :class:`botbuilder.azure.BlobStorageSettings`
    """

    def __init__(self, settings: TABBlobStorageSettings):
        if not settings.container_name:
            raise Exception("Container name is required.")

        if settings.credential:
            blob_service_client = BlobServiceClient(
                account_url=settings.account_url, credential=settings.credential
            )

        self.__container_client = blob_service_client.get_container_client(
            settings.container_name
        )

        self.__initialized = False

    async def _initialize(self):
        if self.__initialized is False:
            # This should only happen once - assuming this is a singleton.
            # ContainerClient.exists() method is available in an unreleased version of the SDK. Until then, we use:
            try:
                await self.__container_client.create_container()
            except ResourceExistsError:
                pass
            self.__initialized = True
        return self.__initialized

    async def read(self, keys: List[str], target_cls=None) -> Dict[str, object]:
        """Retrieve entities from the configured blob container.

        :param keys: An array of entity keys.
        :type keys: List[str]
        :param target_cls: Target class for deserialization (for compatibility with SDK)
        :type target_cls: type
        :return: Dict[str, object]
        """
        if not keys:
            raise Exception("Keys are required when reading")

        print(f"DEBUG: BlobStorage.read() called with keys: {keys}, target_cls: {target_cls}")
        
        await self._initialize()

        items = {}

        for key in keys:
            blob_client = self.__container_client.get_blob_client(key)

            try:
                item = await self._inner_read_blob(blob_client)
                print(f"DEBUG: Successfully read blob for key '{key}': {type(item)} with data: {item}")
                
                # If target_cls is specified, try to create an instance of that class
                if target_cls and isinstance(item, dict):
                    try:
                        # Check if it has the expected from_json_to_store_item method
                        if hasattr(target_cls, 'from_json_to_store_item'):
                            items[key] = target_cls.from_json_to_store_item(item)
                        else:
                            # For CachedAgentState, prepare the state dict with proper hash handling
                            print(f"DEBUG: Processing CachedAgentState data structure: {item.keys()}")
                            
                            # Handle the different data structures we might encounter
                            if 'state' in item and 'hash' in item:
                                # Data stored by our BlobStorage (has 'state' and 'hash' at top level)
                                state_data = item['state'].copy()
                                hash_value = item['hash']
                                e_tag = item.get('e_tag', None)
                                
                                # Add the hash to the state data with the expected key
                                state_data["CachedAgentState._hash"] = hash_value
                                
                                print(f"DEBUG: Reconstructed state_data keys for CachedAgentState: {list(state_data.keys())}")
                                instance = target_cls(state_data)
                                
                                # Set e_tag if the instance supports it
                                if hasattr(instance, 'e_tag') and e_tag:
                                    instance.e_tag = e_tag
                                    
                                items[key] = instance
                                print(f"DEBUG: Successfully created CachedAgentState instance")
                            else:
                                # Direct state data (fallback for other formats)
                                state_data = item.copy()
                                e_tag = state_data.pop('e_tag', None)
                                
                                # For CachedAgentState, ensure hash is properly handled
                                if target_cls.__name__ == 'CachedAgentState':
                                    # If no hash exists, compute a simple one to avoid circular dependency
                                    if "CachedAgentState._hash" not in state_data:
                                        # Create a simple hash based on the content
                                        content_str = json.dumps(state_data, sort_keys=True, default=str)
                                        state_data["CachedAgentState._hash"] = abs(hash(content_str))
                                
                                instance = target_cls(state_data)
                                
                                # Set e_tag if the instance supports it
                                if hasattr(instance, 'e_tag') and e_tag:
                                    instance.e_tag = e_tag
                                    
                                items[key] = instance
                    except Exception as e:
                        print(f"DEBUG: Error creating {target_cls.__name__} instance: {e}")
                        print(f"DEBUG: Exception type: {type(e)}")
                        import traceback
                        print(f"DEBUG: Full traceback: {traceback.format_exc()}")
                        
                        # For CachedAgentState errors, try our manual reconstruction
                        if target_cls.__name__ == 'CachedAgentState' and 'state' in item:
                            try:
                                print(f"DEBUG: Attempting manual CachedAgentState reconstruction")
                                # Create empty state first
                                empty_state = {}
                                # Add a hash to avoid circular dependency
                                empty_state["CachedAgentState._hash"] = abs(hash("empty"))
                                
                                instance = target_cls(empty_state)
                                # Now manually set the state from our stored data
                                instance.state = item['state']
                                instance.hash = item['hash']
                                
                                if hasattr(instance, 'e_tag') and 'e_tag' in item:
                                    instance.e_tag = item['e_tag']
                                    
                                items[key] = instance
                                print(f"DEBUG: Manual reconstruction successful")
                            except Exception as manual_error:
                                print(f"DEBUG: Manual reconstruction failed: {manual_error}")
                                # Final fallback: return the raw item
                                items[key] = item
                        else:
                            # Final fallback: return the raw item
                            items[key] = item
                else:
                    items[key] = item
                    
            except HttpResponseError as err:
                if err.status_code == 404:
                    print(f"DEBUG: Blob not found for key '{key}' (404)")
                    continue
                else:
                    print(f"DEBUG: HTTP error for key '{key}': {err.status_code} - {err}")
                    raise

        print(f"DEBUG: BlobStorage.read() returning {len(items)} items: {list(items.keys())}")
        return items

    async def write(self, changes: Dict[str, object]):
        """Stores a new entity in the configured blob container.

        :param changes: The changes to write to storage.
        :type changes: Dict[str, object]
        :return:
        """
        if changes is None:
            raise Exception("Changes are required when writing")
        if not changes:
            return

        print(f"DEBUG: BlobStorage.write() called with {len(changes)} changes: {list(changes.keys())}")
        for key, item in changes.items():
            print(f"DEBUG: Writing key '{key}': {type(item)} with content: {item}")

        await self._initialize()

        for name, item in changes.items():
            blob_reference = self.__container_client.get_blob_client(name)

            e_tag = None
            if isinstance(item, dict):
                e_tag = item.get("e_tag", None)
            elif hasattr(item, "e_tag"):
                e_tag = item.e_tag
            e_tag = None if e_tag == "*" else e_tag
            if e_tag == "":
                raise Exception("blob_storage.write(): etag missing")

            item_str = self._store_item_to_str(item)

            try:
                if e_tag:
                    await blob_reference.upload_blob(
                        item_str, match_condition=MatchConditions.IfNotModified, etag=e_tag
                    )
                else:
                    await blob_reference.upload_blob(item_str, overwrite=True)
                print(f"DEBUG: Successfully wrote blob for key '{name}'")
            except Exception as e:
                print(f"DEBUG: Error writing blob for key '{name}': {e}")
                raise

    async def delete(self, keys: List[str]):
        """Deletes entity blobs from the configured container.

        :param keys: An array of entity keys.
        :type keys: Dict[str, object]
        """
        if keys is None:
            raise Exception("BlobStorage.delete: keys parameter can't be null")

        await self._initialize()

        for key in keys:
            blob_client = self.__container_client.get_blob_client(key)
            try:
                await blob_client.delete_blob()
            # We can't delete what's already gone.
            except ResourceNotFoundError:
                pass

    def _store_item_to_str(self, item: object) -> str:
        """Convert an object to JSON string for storage."""
        def json_serializer(obj):
            """Custom JSON serializer for special types."""
            if hasattr(obj, 'isoformat'):  # datetime objects
                return obj.isoformat()
            elif hasattr(obj, '__dict__'):
                return obj.__dict__
            return str(obj)
        
        try:
            # Try to serialize as JSON first (for simple objects)
            if hasattr(item, '__dict__'):
                # For objects with attributes, convert to dict
                item_dict = item.__dict__.copy()
                return json.dumps(item_dict, default=json_serializer)
            else:
                # For simple types
                return json.dumps(item, default=json_serializer)
        except (TypeError, ValueError):
            # Fallback to pickle for complex objects
            pickled_data = pickle.dumps(item)
            encoded_data = base64.b64encode(pickled_data).decode('utf-8')
            return json.dumps({"__pickled__": encoded_data})

    async def _inner_read_blob(self, blob_client: BlobClient):
        blob = await blob_client.download_blob()

        return await self._blob_to_store_item(blob)

    @staticmethod
    async def _blob_to_store_item(blob: StorageStreamDownloader) -> object:
        """Convert blob content back to object."""
        content = await blob.content_as_text()
        item = json.loads(content)
        
        # Add etag to the item
        if isinstance(item, dict):
            item["e_tag"] = blob.properties.etag.replace('"', "")
            
            # Check if this was pickled data
            if "__pickled__" in item:
                import base64
                encoded_data = item["__pickled__"]
                pickled_data = base64.b64decode(encoded_data.encode('utf-8'))
                result = pickle.loads(pickled_data)
                # Add etag to unpickled object if possible
                if hasattr(result, '__dict__'):
                    result.e_tag = blob.properties.etag.replace('"', "")
                return result
        
        return item
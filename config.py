from os import environ
from dotenv import load_dotenv
import json
import re

# Load environment variables from .env file
load_dotenv()


class DefaultConfig:
    """Agent Configuration"""

    def __init__(self) -> None:
        self.AUTH_TYPE = environ.get("AUTH_TYPE", "client_secret")
        self.PORT = int(environ.get("PORT", "3978"))

        # Tenant and app registration configuration (host + guest for Teams/Bot integration)
        self.TENANT_ID = environ.get("TENANT_ID", "")
        self.HOST_TENANT_ID = environ.get("HOST_TENANT_ID", "")
        self.CLIENT_ID = environ.get("CLIENT_ID", "")
        self.CLIENT_SECRET = environ.get("CLIENT_SECRET", "")
        
        # Azure OpenAI Configuration
        self.AZURE_OPENAI_ENDPOINT = environ.get("az_openai_endpoint")
        self.AZURE_OPENAI_DEPLOYMENT = environ.get("az_deployment_name")
        self.AZURE_OPENAI_API_VERSION = environ.get("az_openai_api_version")
        self.HUB_CITIES = environ.get("hub_cities", "")
        
        # Configuration for graph_build.py compatibility
        self.az_openai_endpoint = environ.get("az_openai_endpoint")
        self.az_deployment_name = environ.get("az_deployment_name")
        self.az_api_type = environ.get("az_api_type", "azure")
        self.az_openai_api_version = environ.get("az_openai_api_version")
        self.hub_cities = environ.get("hub_cities", "")
        self.az_application_insights_key = environ.get("az_application_insights_key")
        self.log_level = environ.get("log_level", "INFO")
        
        # Debug: Print the key to see if it's loaded correctly
        if self.az_application_insights_key:
            print(f"DEBUG: Application Insights key loaded (length: {len(self.az_application_insights_key)})")
        else:
            print("WARNING: Application Insights key is None or empty!")
            print(f"Environment keys available: {list(environ.keys())}")
        
        # Azure Assistant Configuration
        self.AZURE_ASSISTANT_ID = environ.get("az_assistant_id")
        self.az_assistant_id = environ.get("az_assistant_id")
        
        # Hub-specific Assistant File IDs (parse JSON from environment)
        self._hub_assistant_file_ids = {}
        hub_file_ids_json = environ.get("hub_assistant_file_ids", "{}")
        try:
            self._hub_assistant_file_ids = json.loads(hub_file_ids_json)
        except json.JSONDecodeError:
            print(f"WARNING: Invalid JSON format in hub_assistant_file_ids: {hub_file_ids_json}")
            self._hub_assistant_file_ids = {}
        
        # Legacy file_ids for backward compatibility
        self.FILE_IDS = environ.get("file_ids")
        self.file_ids = environ.get("file_ids")
        
        # Azure Blob Storage Configuration
        self.AZURE_BLOB_STORAGE_ACCOUNT_NAME = environ.get("az_blob_storage_account_name")
        self.AZURE_BLOB_CONTAINER_NAME = environ.get("az_blob_container_name")
        self.AZURE_BLOB_CONTAINER_NAME_HUBMASTER = environ.get("az_blob_container_name_hubmaster")
        self.AZURE_BLOB_CONTAINER_NAME_STATE = environ.get("az_blob_container_name_state")
        self.AZURE_STORAGE_RG = environ.get("az_storage_rg")

        # Configuration for tools compatibility / convenience
        self.az_blob_storage_account_name = environ.get("az_blob_storage_account_name")
        self.az_storage_account_name = self.az_blob_storage_account_name
        self.az_storage_container_name = environ.get("az_blob_container_name")
        self.az_blob_container_name_hubmaster = environ.get("az_blob_container_name_hubmaster")
        self.az_blob_container_name_state = environ.get("az_blob_container_name_state")
        self.az_blob_golden_docs_container_name = environ.get("az_blob_golden_docs_container_name", "golden-repo")
        self.az_subscription_id = environ.get("az_subscription_id")
        # Prefer explicit az_storage_rg_name, fall back to az_storage_rg for backward compatibility
        self.az_storage_rg_name = environ.get("az_storage_rg_name") or environ.get("az_storage_rg")
        self.az_storage_rg = environ.get("az_storage_rg")
        
        # Azure Key Vault Configuration
        self.az_key_vault_name = environ.get("akv")
    
    def normalize_hub_name(self, hub_name: str) -> str:
        """
        Normalize hub name by removing spaces, special characters, and converting to lowercase.
        
        Args:
            hub_name: The original hub name (e.g., "New Delhi", "BENGALURU", "mumbai")
            
        Returns:
            Normalized hub name (e.g., "newdelhi", "bengaluru", "mumbai")
        """
        if not hub_name:
            return ""
        # Remove spaces and special characters, keep only alphanumeric, convert to lowercase
        return re.sub(r'[^a-zA-Z0-9]', '', hub_name).lower()
    
    def get_hub_assistant_file_id(self, hub_name: str) -> str:
        """
        Get the assistant file ID for a specific hub.
        
        Args:
            hub_name: The hub name (case-insensitive, spaces/special chars will be normalized)
            
        Returns:
            The assistant file ID for the hub, or None if not found
        """
        if not hub_name:
            return None
            
        normalized_name = self.normalize_hub_name(hub_name)
        file_id = self._hub_assistant_file_ids.get(normalized_name)
        
        if not file_id:
            # Log available keys for debugging
            available_keys = list(self._hub_assistant_file_ids.keys())
            print(f"WARNING: No assistant file ID found for hub '{hub_name}' (normalized: '{normalized_name}')")
            print(f"Available hub keys: {available_keys}")
            
        return file_id
    
    def get_hub_assistant_id(self, hub_name: str) -> str:
        """
        Get the assistant ID for a specific hub.
        Currently returns the global assistant ID, but can be extended to support hub-specific assistants.
        
        Args:
            hub_name: The hub name 
            
        Returns:
            The assistant ID (currently global, but extensible for hub-specific assistants)
        """
        # For now, return the global assistant ID
        # This method is created for future extensibility if different hubs need different assistants
        return self.az_assistant_id
    
    def get_all_hub_file_ids(self) -> dict:
        """
        Get all hub assistant file IDs.
        
        Returns:
            Dictionary mapping normalized hub names to file IDs
        """
        return self._hub_assistant_file_ids.copy()
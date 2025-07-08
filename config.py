from os import environ
from microsoft.agents.authentication.msal import AuthTypes, MsalAuthConfiguration


class DefaultConfig(MsalAuthConfiguration):
    """Agent Configuration"""

    def __init__(self) -> None:
        self.AUTH_TYPE = AuthTypes.client_secret
        self.TENANT_ID = "" or environ.get("TENANT_ID")
        self.CLIENT_ID = "" or environ.get("CLIENT_ID")
        self.CLIENT_SECRET = "" or environ.get("CLIENT_SECRET")
        self.PORT = 3978
        
        # Azure OpenAI Configuration
        self.AZURE_OPENAI_ENDPOINT = environ.get("az_openai_endpoint")
        self.AZURE_OPENAI_DEPLOYMENT = environ.get("az_deployment_name")
        self.AZURE_OPENAI_API_VERSION = environ.get("az_openai_api_version")
        self.HUB_CITIES = environ.get("hub_cities", "")
        
        # Azure Assistant Configuration
        self.AZURE_ASSISTANT_ID = environ.get("az_assistant_id")
        self.FILE_IDS = environ.get("file_ids")
        
        # Azure Blob Storage Configuration
        self.AZURE_BLOB_STORAGE_ACCOUNT_NAME = environ.get("az_blob_storage_account_name")
        self.AZURE_BLOB_CONTAINER_NAME = environ.get("az_blob_container_name")
        self.AZURE_BLOB_CONTAINER_NAME_HUBMASTER = environ.get("az_blob_container_name_hubmaster")
        self.AZURE_BLOB_CONTAINER_NAME_STATE = environ.get("az_blob_container_name_state")
        self.AZURE_STORAGE_RG = environ.get("az_storage_rg")
        
        # Logging Configuration
        self.LOG_LEVEL = environ.get("log_level", "INFO")
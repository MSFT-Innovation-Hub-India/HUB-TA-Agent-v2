from os import environ
from microsoft.agents.authentication.msal import AuthTypes, MsalAuthConfiguration
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()


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
        self.FILE_IDS = environ.get("file_ids")
        self.az_assistant_id = environ.get("az_assistant_id")
        self.file_ids = environ.get("file_ids")
        
        # Azure Blob Storage Configuration
        self.AZURE_BLOB_STORAGE_ACCOUNT_NAME = environ.get("az_blob_storage_account_name")
        self.AZURE_BLOB_CONTAINER_NAME = environ.get("az_blob_container_name")
        self.AZURE_BLOB_CONTAINER_NAME_HUBMASTER = environ.get("az_blob_container_name_hubmaster")
        self.AZURE_BLOB_CONTAINER_NAME_STATE = environ.get("az_blob_container_name_state")
        self.AZURE_STORAGE_RG = environ.get("az_storage_rg")
        
        # Configuration for tools compatibility
        self.az_storage_account_name = environ.get("az_blob_storage_account_name")
        self.az_blob_container_name_hubmaster = environ.get("az_blob_container_name_hubmaster")
        self.az_blob_container_name_state = environ.get("az_blob_container_name_state")
        self.az_subscription_id = environ.get("az_subscription_id")
        self.az_storage_rg_name = environ.get("az_storage_rg")  # Using same as az_storage_rg
        
        # Logging Configuration
        self.LOG_LEVEL = environ.get("log_level", "INFO")
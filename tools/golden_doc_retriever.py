from config import DefaultConfig
import logging
from opencensus.ext.azure.log_exporter import AzureLogHandler
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
import traceback
from langchain_core.tools import tool

# Create config instance
config = DefaultConfig()

logger = logging.getLogger(__name__)

# Only add Azure log handler if the connection string is available
if config.az_application_insights_key:
    logger.addHandler(AzureLogHandler(connection_string=config.az_application_insights_key))
else:
    print("WARNING: Azure Application Insights key not found in golden_doc_retriever, skipping Azure logging")

# Set the logging level based on the configuration
log_level_str = config.log_level.upper()
log_level = getattr(logging, log_level_str, logging.INFO)
logger.setLevel(log_level)


def retrieve_and_customize_document(
    blob_name: str,
    customer_name: str,
    engagement_type: str,
    date_of_engagement: str,
    venue: str,
    hub_location: str = None
) -> dict:
    """
    Retrieve a golden document from Azure Blob Storage and customize it with customer information.
    This is used as a node function similar to set_prompt_template.
    
    Args:
        blob_name: The name of the blob document in Azure Storage (e.g., "Agenda - Solution Envisioning – DataAI.md")
        customer_name: The customer's name to replace in the document
        engagement_type: The type of engagement (e.g., SOLUTION_ENVISIONING, ADS)
        date_of_engagement: The date of engagement in DD-MMM-YYYY format
        venue: The venue for the engagement
        hub_location: The hub location for retrieving the document (optional)
        
    Returns:
        dict: {"golden_document_content": str} or {"golden_document_content": None} with error logged
    """
    logger.debug(f"Retrieving and customizing golden document: {blob_name}")
    
    # First retrieve the document
    retrieval_result = _retrieve_golden_document_internal(blob_name, hub_location)
    
    if retrieval_result["error"]:
        logger.error(f"Failed to retrieve document: {retrieval_result['error']}")
        return {"golden_document_content": f"Error: {retrieval_result['error']}"}
    
    # Now customize the document
    document_content = retrieval_result["document_content"]
    
    try:
        # Replace placeholders with actual values
        customized_content = document_content
        
        # Replace customer name variations
        customized_content = customized_content.replace("$CustomerName", customer_name)
        customized_content = customized_content.replace("$Customer Name", customer_name)
        
        # Replace engagement type
        customized_content = customized_content.replace("$EngagementType", engagement_type)
        customized_content = customized_content.replace("$Engagement Type", engagement_type)
        
        # Replace date
        customized_content = customized_content.replace("$Date", date_of_engagement)
        
        # Replace venue/location variations
        customized_content = customized_content.replace("$Venue", venue)
        customized_content = customized_content.replace("$LocationName", venue)
        customized_content = customized_content.replace("$locationName", venue)
        customized_content = customized_content.replace("$Location", venue)
        
        logger.debug(f"Successfully customized document. Length: {len(customized_content)} characters")
        
        return {"golden_document_content": customized_content}
        
    except Exception as e:
        error_msg = f"Error customizing document: {str(e)}"
        logger.error(error_msg)
        logger.error(traceback.format_exc())
        return {"golden_document_content": f"Error: {error_msg}"}


@tool
def retrieve_and_customize_golden_document(
    blob_name: str,
    customer_name: str,
    engagement_type: str,
    date_of_engagement: str,
    venue: str,
    hub_location: str = None
) -> dict:
    """
    Retrieve a golden document from Azure Blob Storage and customize it with customer information.
    
    Args:
        blob_name: The name of the blob document in Azure Storage (e.g., "Agenda - Solution Envisioning – DataAI.md")
        customer_name: The customer's name to replace in the document
        engagement_type: The type of engagement (e.g., SOLUTION_ENVISIONING, ADS)
        date_of_engagement: The date of engagement in DD-MMM-YYYY format
        venue: The venue for the engagement
        hub_location: The hub location for retrieving the document (optional)
        
    Returns:
        dict: {"customized_content": str, "error": str or None}
    """
    logger.debug(f"retrieve_and_customize_golden_document called with parameters:")
    logger.debug(f"  blob_name: {blob_name}")
    logger.debug(f"  hub_location: {hub_location}")
    logger.debug(f"  customer_name: {customer_name}")
    
    # First retrieve the document
    retrieval_result = _retrieve_golden_document_internal(blob_name, hub_location)
    
    if retrieval_result["error"]:
        return {
            "customized_content": None,
            "error": retrieval_result["error"]
        }
    
    # Now customize the document
    document_content = retrieval_result["document_content"]
    
    try:
        # Replace placeholders with actual values
        customized_content = document_content
        
        # Replace customer name variations
        customized_content = customized_content.replace("$CustomerName", customer_name)
        customized_content = customized_content.replace("$Customer Name", customer_name)
        
        # Replace engagement type
        customized_content = customized_content.replace("$EngagementType", engagement_type)
        customized_content = customized_content.replace("$Engagement Type", engagement_type)
        
        # Replace date
        customized_content = customized_content.replace("$Date", date_of_engagement)
        
        # Replace venue/location variations
        customized_content = customized_content.replace("$Venue", venue)
        customized_content = customized_content.replace("$LocationName", venue)
        customized_content = customized_content.replace("$locationName", venue)
        customized_content = customized_content.replace("$Location", venue)
        
        logger.debug(f"Successfully customized document. Length: {len(customized_content)} characters")
        
        return {
            "customized_content": customized_content,
            "error": None
        }
        
    except Exception as e:
        error_msg = f"Error customizing document: {str(e)}"
        logger.error(error_msg)
        logger.error(traceback.format_exc())
        return {
            "customized_content": None,
            "error": error_msg
        }


def _retrieve_golden_document_internal(blob_name: str, hub_location: str = None) -> dict:
    """
    Retrieve a markdown document from Azure Blob Storage using authenticated access.
    
    Args:
        blob_name: The name of the blob document (e.g., "Agenda - Solution Envisioning – DataAI.md")
        hub_location: The hub location (e.g., "bengaluru", "dubai"). If not provided, tries to get from config.
        
    Returns:
        dict: {"document_content": str, "error": str or None}
    """
    logger.debug(f"Retrieving golden document: {blob_name}")
    logger.debug(f"_retrieve_golden_document_internal called with hub_location: {hub_location}")
    
    try:
        # Get hub location - use provided value or try to get first hub city from config as fallback
        if not hub_location:
            # Try to get first hub city from config as a fallback
            hub_cities = config.hub_cities.strip() if config.hub_cities else ""
            if hub_cities:
                # Take the first city from the comma-separated list
                hub_location = hub_cities.split(',')[0].strip()
            else:
                # Default fallback
                hub_location = "bengaluru"
        
        # Normalize the hub location name
        normalized_hub_location = config.normalize_hub_name(hub_location)
        
        # Construct the blob path: hub-{city}/documents/{document_name}
        full_blob_name = f"hub-{normalized_hub_location}/documents/{blob_name}"
        
        logger.debug(f"Constructed blob path: {full_blob_name}")
        
        # Get storage account and container name from config
        storage_account_name = config.az_blob_storage_account_name
        container_name = config.az_blob_golden_docs_container_name
        
        if not storage_account_name:
            return {
                "document_content": None,
                "error": "Storage account name not configured (az_blob_storage_account_name)"
            }
        
        if not container_name:
            return {
                "document_content": None,
                "error": "Golden docs container name not configured (az_blob_golden_docs_container_name)"
            }
        
        logger.debug(f"Using storage account: {storage_account_name}, container: {container_name}")
        
        # Create BlobServiceClient using DefaultAzureCredential for authenticated access
        account_url = f"https://{storage_account_name}.blob.core.windows.net"
        credential = DefaultAzureCredential()
        
        blob_service_client = BlobServiceClient(
            account_url=account_url,
            credential=credential
        )
        
        # Get the blob client
        blob_client = blob_service_client.get_blob_client(
            container=container_name,
            blob=full_blob_name
        )
        
        # Check if blob exists
        if not blob_client.exists():
            logger.error(f"Blob does not exist: {full_blob_name}")
            return {
                "document_content": None,
                "error": f"Document not found in blob storage: {full_blob_name}"
            }
        
        # Download the blob content
        download_stream = blob_client.download_blob()
        document_content = download_stream.readall().decode('utf-8')
        
        logger.debug(f"Successfully retrieved document. Length: {len(document_content)} characters")
        
        return {
            "document_content": document_content,
            "error": None
        }
        
    except Exception as e:
        error_msg = f"Error retrieving document from blob storage: {str(e)}"
        logger.error(error_msg)
        logger.error(traceback.format_exc())
        return {
            "document_content": None,
            "error": error_msg
        }


def get_agenda_tags_from_mapping(hub_location: str = None) -> dict:
    """
    Load and parse the agenda_mapping.md file from Azure Blob Storage to extract tags and document URLs.
    
    Args:
        hub_location: The hub location (e.g., "bengaluru", "mumbai"). If not provided, tries to get from config.
    
    Returns:
        dict: {
            "primary_tags": list of unique primary tags,
            "mappings": list of dicts with primary_tags, secondary_tags, and document_url
        }
    """
    try:
        # Get hub location - use provided value or try to get first hub city from config as fallback
        logger.debug(f"get_agenda_tags_from_mapping called with hub_location: {hub_location}")
        
        if not hub_location:
            # Try to get first hub city from config as a fallback
            hub_cities = config.hub_cities.strip() if config.hub_cities else ""
            logger.debug(f"No hub_location provided, checking config.hub_cities: '{hub_cities}'")
            if hub_cities:
                # Take the first city from the comma-separated list
                hub_location = hub_cities.split(',')[0].strip()
                logger.debug(f"Using first city from config: {hub_location}")
            else:
                # Default fallback
                hub_location = "bengaluru"
                logger.debug(f"Using default fallback: {hub_location}")
        
        # Normalize the hub location name
        normalized_hub_location = config.normalize_hub_name(hub_location)
        logger.debug(f"Normalized hub location: {normalized_hub_location}")
        
        # Construct the blob path: hub-{city}/agenda_mapping.md
        blob_name = f"hub-{normalized_hub_location}/agenda_mapping.md"
        
        logger.debug(f"Retrieving agenda mapping from Azure Blob Storage: {blob_name}")
        
        # Get storage account and container name from config
        storage_account_name = config.az_blob_storage_account_name
        container_name = config.az_blob_golden_docs_container_name
        
        if not storage_account_name:
            logger.error("Storage account name not configured (az_blob_storage_account_name)")
            return {"primary_tags": [], "mappings": []}
        
        if not container_name:
            logger.error("Golden docs container name not configured (az_blob_golden_docs_container_name)")
            return {"primary_tags": [], "mappings": []}
        
        logger.debug(f"Using storage account: {storage_account_name}, container: {container_name}")
        
        # Create BlobServiceClient using DefaultAzureCredential for authenticated access
        account_url = f"https://{storage_account_name}.blob.core.windows.net"
        credential = DefaultAzureCredential()
        
        blob_service_client = BlobServiceClient(
            account_url=account_url,
            credential=credential
        )
        
        # Get the blob client
        blob_client = blob_service_client.get_blob_client(
            container=container_name,
            blob=blob_name
        )
        
        # Check if blob exists
        if not blob_client.exists():
            logger.error(f"Agenda mapping blob does not exist: {blob_name}")
            return {"primary_tags": [], "mappings": []}
        
        # Download the blob content
        download_stream = blob_client.download_blob()
        content = download_stream.readall().decode('utf-8')
        
        logger.debug(f"Successfully retrieved agenda mapping. Length: {len(content)} characters")
        
        # Parse the markdown table content
        lines = content.strip().split('\n')
        
        # Find the table start (skip header lines and separator)
        table_start = 0
        for i, line in enumerate(lines):
            if '|' in line and 'Primary Tags' in line:
                table_start = i + 2  # Skip header and separator
                break
        
        mappings = []
        primary_tags_set = set()
        
        # Parse each row
        for line in lines[table_start:]:
            if not line.strip() or '|' not in line:
                continue
                
            # Split by | and clean up
            parts = [p.strip() for p in line.split('|')]
            if len(parts) >= 4:
                primary_tags_str = parts[1].strip()
                secondary_tags_str = parts[2].strip()
                document_name = parts[3].strip()
                
                # Parse tags (they're comma-separated and quoted)
                primary_tags = [tag.strip().strip('"') for tag in primary_tags_str.split(',') if tag.strip()]
                secondary_tags = [tag.strip().strip('"') for tag in secondary_tags_str.split(',') if tag.strip()]
                
                # Add to primary tags set
                for tag in primary_tags:
                    if tag:
                        primary_tags_set.add(tag)
                
                mappings.append({
                    "primary_tags": primary_tags,
                    "secondary_tags": secondary_tags,
                    "document_name": document_name
                })
        
        logger.debug(f"Loaded {len(mappings)} mappings with {len(primary_tags_set)} unique primary tags")
        
        return {
            "primary_tags": sorted(list(primary_tags_set)),
            "mappings": mappings
        }
        
    except Exception as e:
        logger.error(f"Error reading agenda mapping file: {str(e)}")
        logger.error(traceback.format_exc())
        return {
            "primary_tags": [],
            "mappings": []
        }


def find_document_by_tags(primary_tags: list, secondary_tags: list = None, hub_location: str = None) -> str:
    """
    Find the document name based on selected primary and optional secondary tags.
    
    Args:
        primary_tags: List of selected primary tags
        secondary_tags: Optional list of selected secondary tags
        hub_location: The hub location for retrieving agenda mapping (optional)
        
    Returns:
        str: Document name (blob name) or None if no match found
    """
    mapping_data = get_agenda_tags_from_mapping(hub_location)
    
    # Convert input to sets for easier matching
    primary_set = set(tag.strip() for tag in primary_tags)
    secondary_set = set(tag.strip() for tag in secondary_tags) if secondary_tags else set()
    
    best_match = None
    best_score = 0
    
    for mapping in mapping_data["mappings"]:
        mapping_primary = set(mapping["primary_tags"])
        mapping_secondary = set(mapping["secondary_tags"])
        
        # Calculate match score
        primary_match = len(primary_set.intersection(mapping_primary))
        secondary_match = len(secondary_set.intersection(mapping_secondary)) if secondary_tags else 0
        
        # Require at least one primary tag match
        if primary_match > 0:
            score = primary_match * 10 + secondary_match  # Primary tags weighted more
            if score > best_score:
                best_score = score
                best_match = mapping["document_name"]
    
    return best_match

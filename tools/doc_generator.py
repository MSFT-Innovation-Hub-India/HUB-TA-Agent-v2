import os
import traceback
from langchain_core.tools import tool
from openai import AzureOpenAI
from langchain_openai import AzureChatOpenAI
from config import DefaultConfig
from langchain_core.runnables import RunnableConfig
import time
import json
from azure.storage.blob import BlobServiceClient
import logging
from opencensus.ext.azure.log_exporter import AzureLogHandler
from azure.identity import DefaultAzureCredential
from azure.storage.blob import (
    generate_blob_sas,
    BlobSasPermissions,
)
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.mgmt.storage import StorageManagementClient
from azure.mgmt.storage.models import StorageAccountUpdateParameters
import datetime
from util.az_blob_account_access import set_blob_account_public_access

# Create config instance
l_config = DefaultConfig()
config = l_config  # For backward compatibility

logger = logging.getLogger(__name__)

# Only add Azure log handler if the connection string is available
if l_config.az_application_insights_key:
    logger.addHandler(AzureLogHandler(connection_string=l_config.az_application_insights_key))
else:
    print("WARNING: Azure Application Insights key not found in doc_generator, skipping Azure logging")

# Set the logging level based on the configuration
log_level_str = l_config.log_level.upper()
log_level = getattr(logging, log_level_str, logging.INFO)
logger.setLevel(log_level)
# logger.debug(f"Logging level set to {log_level_str}")
# logger.setLevel(logging.DEBUG)


user_prompt_prefix = """
Use the document format 'Innovation Hub Agenda Format.docx' available with you. Follow the instructions below to add the markdown content under [Agenda for Innovation Hub Session] below into the document. 
- The document contains a table
- The first row is a merged cell across the width of the table. Insert details like Customer Name, Date of the Engagement, Location where the Innovation Hub Session would be held, Engagement Type: (Whether Business Envisioning, or Solution Envisioning, or ADS, or Rapid Prototype or Hackathon, or Consult)
- The second row contains the Column names for the Agenda, like the Time (IST),Speaker, Topic, Description
- From the third row onwards, map the agenda line item content from under [Agenda for Innovation Hub Session] below, and add them into the existing table. **DO NOT CREATE A NEW TABLE**

[Agenda for Innovation Hub Session]
"""

@tool
def generate_agenda_document(query: str, config: RunnableConfig) -> str:
    """Generate a Microsoft Office Word document (.docx) with the draft Agenda for the Customer Engagement provided as user input.

    Args:
        query (str): The agenda items in markdown table format to be included in the document.
        config (dict): Configuration parameters for document generation including customer_name
                      and hub_location for template selection.

    Returns:
        dict: A dictionary containing the status of document generation and file path information.
    """
    print("preparing to generate the agenda Word document .........")

    response = None
    try:
        configuration = config.get("configurable", {})
        hub_location = configuration.get("hub_location", None)
        response = ""
        

        # Get hub-specific assistant ID and file ID if needed
        assistant_id = l_config.get_hub_assistant_id(hub_location) if hub_location else l_config.az_assistant_id
        hub_file_id = l_config.get_hub_assistant_file_id(hub_location) if hub_location else None
        
        if hub_location and not hub_file_id:
            logger.warning(f"No hub-specific file ID found for location: {hub_location}, using default assistant")

        # Initialize Azure OpenAI Service client with Entra ID authentication
        token_provider = get_bearer_token_provider(
            DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default"
        )

        # Use AzureChatOpenAI with Azure OpenAI and Responses API for code interpreter
        llm = AzureChatOpenAI(
            azure_endpoint=l_config.az_openai_endpoint,
            azure_ad_token_provider=token_provider,
            api_version=l_config.az_openai_api_version,
            azure_deployment=l_config.az_deployment_name,
            temperature=0.3,
            use_responses_api=True,
            include=["code_interpreter_call.outputs"]  # Include code interpreter outputs
        )

        # Prepare the file_id for the code interpreter container
        file_id = hub_file_id if hub_file_id else l_config.file_ids
        if file_id and file_id.startswith("file-"):
            # Convert to assistant file ID format if needed
            if not file_id.startswith("assistant-"):
                file_id = f"assistant-{file_id.replace('file-', '')}"
        
        logger.debug(f"Word Document Generator Agent: Using file_id: {file_id}")

        # Bind code interpreter tool with file_ids container
        code_interpreter_tool = {
            "type": "code_interpreter",
            "container": {
                "type": "auto",
                "file_ids": [file_id] if file_id else []
            }
        }
        
        llm_with_tools = llm.bind_tools([code_interpreter_tool])

        # Create the message for the model using structured input
        message_content = f"{user_prompt_prefix}\n\n{query}"
        
        logger.debug(f"Word Document Generator Agent: Message content length: {len(message_content)}")
        logger.debug(f"Word Document Generator Agent: Using file_id: {file_id}")
        logger.debug("Word Document Generator Agent: Calling Responses API with code interpreter...")

        # Invoke the model with Responses API
        response = llm_with_tools.invoke([{"role": "user", "content": message_content}])

        logger.debug("Word Document Generator Agent: Response received from Responses API")

        # Extract file information from the response
        l_file_id = None
        l_file_name = None

        logger.debug(f"Word Document Generator Agent: Response type: {type(response)}")
        logger.debug(f"Word Document Generator Agent: Response content: {response.content}")
        
        # Check if response has content_blocks (for Responses API) or if we need to check content/tool_calls
        if hasattr(response, 'content_blocks') and response.content_blocks:
            logger.debug(f"Word Document Generator Agent: Parsing response with {len(response.content_blocks)} content blocks")
            # Look for code interpreter calls and text annotations in the response content
            for content_block in response.content_blocks:
                logger.debug(f"Processing content block type: {content_block.get('type')}")
                
                if content_block.get("type") == "code_interpreter_call":
                    # Get outputs from the code interpreter call
                    outputs = content_block.get("outputs", [])
                    logger.debug(f"Found {len(outputs)} outputs in code interpreter call")
                    
                    for output in outputs:
                        output_type = output.get("type")
                        logger.debug(f"Processing output type: {output_type}")
                        
                        # Check for file outputs which might contain our generated document
                        if output_type == "logs":
                            # Sometimes file paths are mentioned in logs
                            logs_text = output.get("logs", "")
                            if "sandbox:/mnt/" in logs_text and ".docx" in logs_text:
                                # Extract file path from logs if present
                                import re
                                file_match = re.search(r'sandbox:/mnt/[^"\']*\.docx', logs_text)
                                if file_match:
                                    file_path = file_match.group(0)
                                    l_file_name = os.path.basename(file_path)
                                    logger.debug(f"Found file path in logs: {file_path}")
                        elif "file_id" in output:
                            l_file_id = output["file_id"]
                            l_file_name = output.get("filename", "generated_document.docx")
                            logger.debug(f"Found file_id in output: {l_file_id}")
                            break
                            
                elif content_block.get("type") == "text":
                    # Look for file annotations in text content
                    annotations = content_block.get("annotations", [])
                    logger.debug(f"Found {len(annotations)} annotations in text block")
                    
                    for annotation in annotations:
                        if annotation.get("type") == "file_path":
                            file_path_str = annotation.get("text", "")
                            logger.debug(f"Processing file path annotation: {file_path_str}")
                            
                            if file_path_str.startswith("sandbox:/mnt"):
                                l_file_id = annotation.get("file_path", {}).get("file_id")
                                l_file_name = os.path.basename(file_path_str)
                                logger.debug(f"Extracted file_id from annotation: {l_file_id}, file name: {l_file_name}")
                                break
                    
                    # Also check the text content itself for file references
                    text_content = content_block.get("text", "")
                    if "sandbox:/mnt/" in text_content and ".docx" in text_content:
                        import re
                        file_match = re.search(r'sandbox:/mnt/[^"\']*\.docx', text_content)
                        if file_match:
                            file_path = file_match.group(0)
                            l_file_name = os.path.basename(file_path)
                            logger.debug(f"Found file reference in text: {file_path}")
        else:
            # AzureChatOpenAI might not have content_blocks, check alternative attributes
            logger.debug("Word Document Generator Agent: No content_blocks found, checking alternative response format")
            
            # Check response.content - it's a list of content dictionaries
            if hasattr(response, 'content') and response.content:
                logger.debug(f"Processing response.content with {len(response.content)} items")
                
                # Iterate through content items looking for annotations with file information
                for content_item in response.content:
                    if isinstance(content_item, dict):
                        # Check for annotations in this content item
                        annotations = content_item.get('annotations', [])
                        logger.debug(f"Found {len(annotations)} annotations in content item")
                        
                        for annotation in annotations:
                            if annotation.get('type') == 'container_file_citation':
                                l_file_id = annotation.get('file_id')
                                l_file_name = annotation.get('filename', 'generated_document.docx')
                                logger.debug(f"Found file_id in annotation: {l_file_id}, filename: {l_file_name}")
                                break
                        
                        # Also check the text content for file references
                        text_content = content_item.get('text', '')
                        if "sandbox:/mnt/" in text_content and ".docx" in text_content:
                            import re
                            file_match = re.search(r'sandbox:/mnt/[^"\']*\.docx', text_content)
                            if file_match:
                                file_path = file_match.group(0)
                                if not l_file_name:  # Only set if not already found from annotation
                                    l_file_name = os.path.basename(file_path)
                                logger.debug(f"Found file reference in text content: {file_path}")
                    
                    # Break if we found the file info
                    if l_file_id:
                        break

        # Check if response has tool_calls that might contain file info
        if not l_file_id and hasattr(response, 'tool_calls') and response.tool_calls:
            logger.debug("Checking tool_calls for file information")
            for tool_call in response.tool_calls:
                logger.debug(f"Processing tool call: {tool_call}")
                if hasattr(tool_call, 'type') and tool_call.type == 'code_interpreter_call':
                    # Check if there are any results with file information
                    if hasattr(tool_call, 'results'):
                        results = tool_call.results
                        for result in results:
                            if 'file_id' in result:
                                l_file_id = result['file_id']
                                l_file_name = result.get('filename', 'generated_document.docx')
                                logger.debug(f"Found file_id in tool_call results: {l_file_id}")
                                break

        # Additional check for response metadata or additional_kwargs
        if not l_file_id and hasattr(response, 'additional_kwargs'):
            logger.debug(f"Checking additional_kwargs for file information")
            additional_kwargs = response.additional_kwargs
            
            # Check if there are tool_outputs with code interpreter results
            if 'tool_outputs' in additional_kwargs:
                tool_outputs = additional_kwargs['tool_outputs']
                for tool_output in tool_outputs:
                    if tool_output.get('type') == 'code_interpreter_call':
                        # Check the outputs for file references
                        outputs = tool_output.get('outputs', [])
                        for output in outputs:
                            if output.get('type') == 'logs':
                                logs_text = output.get('logs', '')
                                # Look for file path in logs
                                if '/mnt/data/' in logs_text and '.docx' in logs_text:
                                    import re
                                    # Extract the file path from the logs
                                    file_match = re.search(r"'(/mnt/data/[^']*\.docx)'", logs_text)
                                    if file_match:
                                        file_path = file_match.group(1)
                                        if not l_file_name:  # Only set if not already found
                                            l_file_name = os.path.basename(file_path)
                                        logger.debug(f"Found file path in tool output logs: {file_path}")
                                        
                        # Also check if there's a container_id that we can use
                        container_id = tool_output.get('container_id')
                        if container_id and not l_file_id:
                            # We might need to construct or look for the file_id differently
                            logger.debug(f"Found container_id in tool output: {container_id}")
            
            logger.debug(f"Additional kwargs keys: {list(additional_kwargs.keys())}")
            
        if not l_file_id and hasattr(response, 'response_metadata'):
            logger.debug(f"Checking response_metadata: {response.response_metadata}")

        if not l_file_id:
            logger.error("Word Document Generator Agent: No file_id found in the response")
            logger.debug(f"Response attributes: {dir(response)}")
            if hasattr(response, 'content_blocks'):
                logger.debug(f"Response content blocks: {[block.get('type') for block in response.content_blocks]}")
            return "Sorry, I was unable to generate the Word document. The code interpreter may not have created a file output. Please try again later."
        
        # Log the found file information
        logger.debug(f"Successfully extracted - file_id: {l_file_id}, file_name: {l_file_name}")

        # Initialize a regular OpenAI client to download the file
        client = AzureOpenAI(
            azure_endpoint=l_config.az_openai_endpoint,
            azure_ad_token_provider=token_provider,
            api_version=l_config.az_openai_api_version,
        )

        # Extract container_id from the response annotations for proper file access
        container_id = None
        if hasattr(response, 'content') and response.content:
            for content_item in response.content:
                if isinstance(content_item, dict):
                    annotations = content_item.get('annotations', [])
                    for annotation in annotations:
                        if annotation.get('type') == 'container_file_citation':
                            container_id = annotation.get('container_id')
                            logger.debug(f"Found container_id: {container_id}")
                            break
                    if container_id:
                        break

        try:
            # Use the container files API to download files created by code interpreter
            if container_id:
                logger.debug(f"Using container files API - container_id: {container_id}, file_id: {l_file_id}")
                
                # Construct the container file endpoint URL
                # According to OpenAI docs: /v1/containers/{container_id}/files/{file_id}/content
                container_file_url = f"{l_config.az_openai_endpoint.rstrip('/')}/openai/v1/containers/{container_id}/files/{l_file_id}/content"
                
                logger.debug(f"Container file URL: {container_file_url}")
                
                # Use requests to get the file content with proper authentication
                import requests
                headers = {
                    'Authorization': f'Bearer {token_provider()}',
                    'api-key': token_provider()  # For Azure OpenAI
                }
                
                # Try both authentication methods
                for auth_header in [{'Authorization': f'Bearer {token_provider()}'}, {'api-key': token_provider()}]:
                    try:
                        response_file = requests.get(container_file_url, headers=auth_header, timeout=60)
                        if response_file.status_code == 200:
                            doc_data_bytes = response_file.content
                            logger.debug(f"Successfully retrieved file using container API, size: {len(doc_data_bytes)} bytes")
                            break
                        else:
                            logger.debug(f"Container API attempt failed with status {response_file.status_code}: {response_file.text}")
                    except Exception as req_error:
                        logger.debug(f"Container API request failed: {str(req_error)}")
                        continue
                else:
                    raise Exception("All container API attempts failed")
                    
            else:
                # Fallback to regular files API
                logger.debug(f"No container_id found, trying regular files API with file_id: {l_file_id}")
                doc_data = client.files.content(l_file_id)
                doc_data_bytes = doc_data.read()
                logger.debug("Successfully retrieved file using regular files API")
                
        except Exception as e:
            logger.error(f"Failed to retrieve file using both container and regular APIs: {str(e)}")
            return f"Sorry, I was able to generate the Word document '{l_file_name}' with the agenda content, but encountered an issue downloading it. The document was created successfully in the code interpreter but cannot be accessed through the download APIs. This may be a temporary issue with the file storage system. Please try running the document generation again."

        blob_account_name = l_config.az_storage_account_name
        az_blob_storage_endpoint = f"https://{blob_account_name}.blob.core.windows.net/"
        blob_container_name = l_config.az_storage_container_name
        az_subscription_id = l_config.az_subscription_id
        az_storage_rg_name = l_config.az_storage_rg_name

        # Upload the document to Azure Blob Storage using managed identity
        response = upload_document_to_blob_storage_using_mi(
            doc_data_bytes,
            az_blob_storage_endpoint,
            blob_account_name,
            blob_container_name,
            l_file_name,
            az_subscription_id,
            az_storage_rg_name,
        )
    except Exception as e:
        logger.error(f"Word Document Generator Agent: Error occurred: {str(e)}")
        logger.error(
            f"Word Document Generator Agent: Error details\n {traceback.format_exc()}"
        )
        response = f"An error occurred when generating the Word document. Please try again later"
    return response


# The wait_for_run function is no longer needed with the Responses API implementation


def upload_document_to_blob_storage_using_mi(
    doc_data_bytes,
    blob_account_url,
    blob_account_name,
    blob_container_name,
    file_name,
    az_subscription_id,
    az_storage_rg_name,
):
    """
    Uploads the document to Azure Blob Storage.
    """

    response = None
    flag = set_blob_account_public_access(
        blob_account_name=blob_account_name,
        az_subscription_id=az_subscription_id,
        az_storage_rg_name=az_storage_rg_name,
    )
    if not flag:
        raise Exception(
            "Issue accessing Storage to upload the document created. Please try again later or contact the TAB administrator."
        )

    logger.debug(
        "Word Document Generator Agent: Uploading document to blob storage using managed identity..."
    )
    # Create a BlobServiceClient using the managed identity credential

    sas_token = None

    # Add retry logic for the upload operation
    max_retries = 3
    retry_delay = 5  # seconds
    success = False
    blob_service_client = None
    container_client = None

    # When the public network access is set to enabled, from disabled, through this program, the upload of document when done immediately fails.
    # So, we need to add a retry logic to upload the document to blob storage, including a delay of 5 seconds between each retry.
    for attempt in range(max_retries):
        try:
            blob_service_client = BlobServiceClient(
                account_url=blob_account_url, credential=DefaultAzureCredential()
            )

            # Create a container client
            container_client = blob_service_client.get_container_client(
                blob_container_name
            )
            logger.debug(f"Upload attempt {attempt+1} of {max_retries}")
            container_client.upload_blob(
                name=file_name, data=doc_data_bytes, overwrite=True
            )
            success = True
            logger.debug(
                f"Word Document Generator Agent: Uploaded document '{file_name}' to blob container '{blob_container_name}' successfully."
            )
            break  # Exit the retry loop if upload succeeds
        except Exception as e:
            logger.warning(
                f"Word Document Generator Agent: Upload attempt {attempt+1} failed: {str(e)}"
            )
            if attempt < max_retries - 1:
                logger.info(
                    f"Word Document Generator Agent: Waiting {retry_delay} seconds before retry..."
                )
                time.sleep(retry_delay)
                retry_delay *= 2  # Exponential backoff
            else:
                logger.error(
                    f"Word Document Generator Agent: All {max_retries} upload attempts failed"
                )
                raise  # Re-raise the exception after all retries fail

    if not success:
        response = f"Word Document Generator Agent: The Word document with the details of the Agenda has been created. However, there was an error while uploading the document to the blob storage. Shall I try once again?"
        return response

    blob_client = container_client.get_blob_client(file_name)
    blob_url = blob_client.url
    # logger.debug(f"Blob URL: {blob_url}")
    logger.debug(
        f"Word Document Generator Agent: Creating a download link for the generated Word Document: Blob URL: {blob_url}"
    )

    # Generate SAS token using user delegation key (Managed Identity)
    # Get user delegation key
    start_time = datetime.datetime.utcnow()
    expiry_time = start_time + datetime.timedelta(days=1)

    try:
        user_delegation_key = blob_service_client.get_user_delegation_key(
            key_start_time=start_time, key_expiry_time=expiry_time
        )

        # Generate SAS token using the user delegation key
        sas_token = generate_blob_sas(
            account_name=blob_account_name,
            container_name=blob_container_name,
            blob_name=file_name,
            user_delegation_key=user_delegation_key,
            permission=BlobSasPermissions(read=True),
            expiry=expiry_time,
        )

        # Create the full URL with SAS token
        sas_url = f"{blob_url}?{sas_token}"
        # logger.debug(f"Blob URL with SAS: {sas_url}")

        response = f'The Word document with the details of the Agenda has been created. Please access it from the url here. <a href="{sas_url}" target="_blank">{sas_url}</a>'
        return response
    except Exception as e:
        logger.error(
            f"Word Document Generator Agent: Failed to generate SAS Token to download the uploaded document: {e}"
        )
        logger.error(f"Word Document Generator Agent: {traceback.format_exc()}")
        response = f"The Word document with the details of the Agenda has been created adn uploaded. However, there was an error getting the download URL for it. Shall I try once again?"
        return response


# This function is used to upload the document to Azure Blob Storage using the storage account key.
# This is not recommended for production use, as it exposes the storage account key.
# It is better to use managed identity or user delegation key for authentication. This function is kept for reference only.


def upload_document_to_blob_storage(
    doc_data_bytes, blob_account_name, blob_account_key, blob_container_name, file_name
):
    """
    Uploads the document to Azure Blob Storage.
    """
    connection_string = f"DefaultEndpointsProtocol=https;AccountName={blob_account_name};AccountKey={blob_account_key};EndpointSuffix=core.windows.net"
    blob_service_client = BlobServiceClient.from_connection_string(connection_string)
    container_client = blob_service_client.get_container_client(blob_container_name)

    try:
        container_client.upload_blob(
            name=file_name, data=doc_data_bytes, overwrite=True
        )
        logger.debug(
            f"Uploaded document '{file_name}' to blob container '{blob_container_name}' successfully."
        )
        blob_client = container_client.get_blob_client(file_name)
        blob_url = blob_client.url
        logger.debug(f"Blob URL: {blob_url}")
        response = f'The Word document with the details of the Agenda has been created. Please access it from the url here. <a href="{blob_url}" target="_blank">{blob_url}</a>'
        return response
    except Exception as e:
        logger.error(f"Failed to upload document: {e}")
        response = f"The Word document with the details of the Agenda has been created. However, there was an error while uploading the document to the blob storage. Please try again later."
        return response


# This is to return the created Word document as an attachment in the response in the chat message
# But since this goes back to the LLM, it hits the token limit, so we are not using it in the application. Retained here only for reference.
# Convert bytes to base64 for attachment
def generate_agenda_document_with_attachment(client, l_file_id, l_file_name) -> str:
    # This is to returned the created Word document as an attachment in the response
    doc_data = client.files.content(l_file_id)
    doc_data_bytes = doc_data.read()

    import base64

    encoded_content = base64.b64encode(doc_data_bytes).decode("utf-8")

    # Create attachment information
    file_attachment = {
        "contentType": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "contentUrl": f"data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64,{encoded_content}",
        "name": l_file_name,
    }

    # Return formatted response with attachment info
    response = {
        "text": "Here's your generated agenda document:",
        "attachments": [file_attachment],
    }
    response = json.dumps(response)

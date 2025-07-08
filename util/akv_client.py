"""
NOTE: This file is retained here only for reference or future use.
It is not currently being used in the application.
"""

import os
from dotenv import load_dotenv
from azure.keyvault.secrets import SecretClient
from azure.identity import DefaultAzureCredential
from azure.mgmt.keyvault import KeyVaultManagementClient
import logging
import time
import traceback

load_dotenv()

""" Azure Key Vault Configuration """
print("initializing AKV to get secrets")
key_vault_name = os.getenv("akv")


def set_key_vault_public_access(
    key_vault_name: str,
    subscription_id: str,
    resource_group_name: str
) -> bool:
    """
    Set the Key Vault public network access to enabled.
    
    Args:
        key_vault_name: Name of the Azure Key Vault
        subscription_id: Azure subscription ID
        resource_group_name: Resource group name containing the Key Vault
        
    Returns:
        True if public access is enabled successfully, False otherwise
    """
    access_set = False
    
    try:
        # Create a credential using DefaultAzureCredential which supports managed identity
        credential = DefaultAzureCredential()
        
        # Create the Key Vault management client
        kv_mgmt_client = KeyVaultManagementClient(credential, subscription_id)
        
        # Get the existing Key Vault
        existing_vault = kv_mgmt_client.vaults.get(resource_group_name, key_vault_name)
        
        # Check if public network access is already enabled
        if existing_vault.properties.public_network_access != "Enabled":
            logging.debug(
                f"Public network access is not enabled for Key Vault '{key_vault_name}'. Updating..."
            )
            
            # Update the properties to enable public network access
            existing_vault.properties.public_network_access = "Enabled"
            
            # Update the Key Vault
            kv_mgmt_client.vaults.create_or_update(resource_group_name, key_vault_name, existing_vault)
            
            # Wait and verify the update
            start_time = time.time()
            flag = True
            while flag:
                logging.debug(
                    f"Checking the status of public network access for Key Vault '{key_vault_name}'..."
                )
                updated_vault = kv_mgmt_client.vaults.get(resource_group_name, key_vault_name)
                
                if updated_vault.properties.public_network_access == "Enabled":
                    logging.debug(
                        f"Public network access for Key Vault '{key_vault_name}' is now enabled."
                    )
                    time.sleep(10)  # Let the access take effect
                    access_set = True
                    flag = False
                    break
                else:
                    time.sleep(5)
                    logging.debug(
                        f"Key Vault '{key_vault_name}' is not enabled for public access, trying again..."
                    )
                    # Beyond 1 minute, break the loop and return an error message
                    if time.time() - start_time > 60:
                        logging.error(
                            f"Timeout: Unable to set public network access for Key Vault '{key_vault_name}' to 'Enabled'."
                        )
                        flag = False
                    continue
        else:
            logging.debug(
                f"Public network access for Key Vault '{key_vault_name}' is already enabled."
            )
            access_set = True
            
    except Exception as ex:
        logging.error(
            f"Error while checking or updating public network access for Key Vault '{key_vault_name}': {str(ex)}"
        )
        logging.error(traceback.format_exc())
        
    return access_set


def get_secret_from_key_vault(secret_name):
    """
    Retrieves a secret from Azure Key Vault using Managed Identity.
    Falls back to environment variables if Key Vault access fails.
    
    Args:
        key_vault_name: Name of the Azure Key Vault
        secret_name: Name of the secret to retrieve
        
    Returns:
        The secret value or None if not found
    """
    try:
        # Create a credential using DefaultAzureCredential which supports managed identity
        credential = DefaultAzureCredential()
        
        # Create the URL to your Key Vault
        key_vault_url = f"https://{key_vault_name}.vault.azure.net/"
        
        # Create the client
        client = SecretClient(vault_url=key_vault_url, credential=credential)
        
        # Get the secret
        secret = client.get_secret(secret_name)
        return secret.value
        
    except Exception as ex:
        logging.warning(f"Could not retrieve secret '{secret_name}' from Key Vault: {str(ex)}")
        # Fall back to environment variable if Key Vault access fails
        return os.getenv(secret_name.replace('-', '_'))



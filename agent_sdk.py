# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

"""TAB Agent implementation using the GA Microsoft 365 Agents SDK."""

import datetime
import re
import logging
import traceback
import uuid
from datetime import timezone, timedelta
from os import environ
from typing import Optional

from dotenv import load_dotenv
from openai import AsyncAzureOpenAI, AzureOpenAI

try:  # GA packages expose both underscore and dotted namespaces depending on version
    from microsoft_agents.activity import load_configuration_from_env
    from microsoft_agents.authentication.msal import MsalConnectionManager
    from microsoft_agents.hosting.aiohttp import CloudAdapter
    from microsoft_agents.hosting.core import (
        AgentApplication,
        Authorization,
        MemoryStorage,
        MessageFactory,
        TurnContext,
        TurnState,
    )
except ImportError:  # pragma: no cover - fallback for environments still publishing dotted namespace
    from microsoft.agents.activity import load_configuration_from_env  # type: ignore[import-not-found]
    from microsoft.agents.authentication.msal import MsalConnectionManager  # type: ignore[import-not-found]
    from microsoft.agents.hosting.aiohttp import CloudAdapter  # type: ignore[import-not-found]
    from microsoft.agents.hosting.core import (  # type: ignore[import-not-found]
        AgentApplication,
        Authorization,
        MemoryStorage,
        MessageFactory,
        TurnContext,
        TurnState,
    )

from azure.identity import DefaultAzureCredential, get_bearer_token_provider

import graph_build
from config import DefaultConfig
from start_server import start_server
from util.az_blob_account_access import set_blob_account_public_access
from util.az_blob_storage import AgentStorageSetting, BlobStorage

load_dotenv()


def _mirror_service_connection_settings() -> None:
    """Populate service connection env vars from base auth settings when omitted."""
    mapping = {
        "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID": "CLIENT_ID",
        "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET": "CLIENT_SECRET",
        "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID": "TENANT_ID",
    }

    for target, source in mapping.items():
        if environ.get(target):
            continue
        source_value = environ.get(source)
        if source_value:
            environ[target] = source_value


_mirror_service_connection_settings()
agents_sdk_config = load_configuration_from_env(environ)
config = DefaultConfig()

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)
handler = logging.StreamHandler()
formatter = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
handler.setFormatter(formatter)
logger.addHandler(handler)

storage_account_name = environ.get("az_blob_storage_account_name", "tabagentstore")
container_name = environ.get("az_blob_container_name_state", "tab-state")
account_url = f"https://{storage_account_name}.blob.core.windows.net/"

blob_storage_settings = AgentStorageSetting(
    container_name=container_name,
    account_url=account_url,
    credential=DefaultAzureCredential(),
)

logger.info(
    "Using MemoryStorage for SDK internal state, and Azure Blob Storage for conversation state"
)
storage = MemoryStorage()

try:
    blob_storage_client = BlobStorage(blob_storage_settings)
    logger.info("Successfully initialized Azure Blob Storage for conversation state management")
    BLOB_STORAGE_AVAILABLE = True
except Exception as exc:
    logger.warning(f"Failed to initialize Azure Blob Storage: {exc}")
    logger.warning("Conversation state will not persist across restarts")
    blob_storage_client = None
    BLOB_STORAGE_AVAILABLE = False

connection_manager = MsalConnectionManager(**agents_sdk_config)
adapter = CloudAdapter(connection_manager=connection_manager)
authorization = Authorization(storage, connection_manager, **agents_sdk_config)

tag_app = AgentApplication[TurnState](
    storage=storage,
    adapter=adapter,
    authorization=authorization,
    **agents_sdk_config,
)

az_openai_endpoint = environ.get("az_openai_endpoint")
az_deployment_name = environ.get("az_deployment_name", "gpt-4o")
az_openai_api_version = environ.get("az_openai_api_version", "2025-01-01-preview")

credential = DefaultAzureCredential()
openai_client: Optional[AsyncAzureOpenAI] = None
sync_openai_client: Optional[AzureOpenAI] = None


def _parse_known_hubs() -> dict[str, str]:
    hubs: dict[str, str] = {}
    if not config.hub_cities:
        return hubs

    for city in (city.strip() for city in config.hub_cities.split(",") if city.strip()):
        normalized = config.normalize_hub_name(city)
        if normalized:
            hubs[normalized] = city
    return hubs


KNOWN_HUBS = _parse_known_hubs()


def _detect_hub_location(message: str) -> Optional[str]:
    if not message:
        return None

    normalized_message = config.normalize_hub_name(message)
    if not normalized_message:
        return None

    for normalized_city, original_city in KNOWN_HUBS.items():
        if normalized_city and normalized_city in normalized_message:
            return original_city

    return None


async def get_azure_token() -> Optional[str]:
    try:
        token = credential.get_token("https://cognitiveservices.azure.com/.default")
        return token.token
    except Exception as exc:
        logger.error(f"Failed to get Azure token: {exc}")
        return None


if az_openai_endpoint:
    try:
        openai_client = AsyncAzureOpenAI(
            azure_endpoint=az_openai_endpoint,
            azure_ad_token_provider=get_azure_token,
            api_version=az_openai_api_version,
        )
        logger.info(f"Azure OpenAI initialized with endpoint: {az_openai_endpoint}")
        try:
            test_token = credential.get_token("https://cognitiveservices.azure.com/.default")
            if test_token:
                logger.info("Azure OpenAI authentication successful")
            else:
                logger.warning("Azure OpenAI authentication may have issues")
        except Exception as exc:
            logger.error(f"Azure authentication test failed: {exc}")
    except Exception as exc:
        logger.error(f"Failed to initialize Azure OpenAI: {exc}")
        openai_client = None
else:
    logger.warning("Azure OpenAI endpoint not configured")


def _get_sync_openai_client() -> Optional[AzureOpenAI]:
    global sync_openai_client

    if sync_openai_client is not None:
        return sync_openai_client

    if not az_openai_endpoint:
        logger.warning("Azure OpenAI endpoint not configured; cannot create sync client")
        return None

    try:
        token_provider = get_bearer_token_provider(
            DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default"
        )
        sync_openai_client = AzureOpenAI(
            azure_endpoint=az_openai_endpoint,
            azure_ad_token_provider=token_provider,
            api_version=az_openai_api_version,
        )
        logger.debug("Initialized synchronous Azure OpenAI client for Assistants API operations")
    except Exception as exc:
        logger.error(f"Failed to initialize synchronous Azure OpenAI client: {exc}")
        sync_openai_client = None

    return sync_openai_client


class ConversationStateManager:
    """Persist conversation state into Azure Blob Storage for load-balanced scenarios."""

    def __init__(self):
        self.initialized = False
        self.blob_storage = None

    async def _initialize(self, context: Optional[TurnContext] = None):
        if self.initialized:
            return

        if not BLOB_STORAGE_AVAILABLE:
            logger.debug("Blob storage unavailable; skipping initialization")
            self.initialized = True
            return

        self.blob_storage = blob_storage_client
        try:
            if context:
                if not await check_blob_storage_access(context):
                    logger.warning("Public access to blob storage could not be enabled")
            self.initialized = True
        except Exception as exc:
            logger.error(f"Failed to initialize conversation state manager: {exc}")
            self.blob_storage = None
            self.initialized = True

    def _get_date_based_blob_key(self, user_name: str) -> str:
        today = datetime.datetime.now(timezone.utc).strftime("%Y%m%d")
        safe_user_name = user_name.replace("|", "_").replace("/", "_")
        return f"conversations/{today}/{safe_user_name}_state"

    async def load_conversation_state(self, user_name: str, context: TurnContext) -> dict:
        await self._initialize(context)

        default_state = {
            "configurable": {
                "user_name": user_name,
                "thread_id": None,
                "asst_thread_id": None,
                "last_message_timestamp": None,
                "hub_location": None,
                "awaiting_hub_location": True,
            }
        }

        if not self.blob_storage:
            logger.debug(f"No blob storage available, using default state for user {user_name}")
            return default_state

        try:
            date_based_key = self._get_date_based_blob_key(user_name)
            result = await self.blob_storage.read([date_based_key])

            if date_based_key in result:
                stored_state = result[date_based_key]
                configurable = stored_state.setdefault("configurable", {})
                configurable.setdefault("hub_location", None)
                configurable.setdefault(
                    "awaiting_hub_location", configurable.get("hub_location") is None
                )
                configurable.setdefault("asst_thread_id", None)
                logger.info(f"Loaded conversation state for user {user_name} from date folder")
                return stored_state

            old_blob_key = f"conversation_state_{user_name}"
            old_result = await self.blob_storage.read([old_blob_key])

            if old_blob_key in old_result:
                stored_state = old_result[old_blob_key]
                configurable = stored_state.setdefault("configurable", {})
                configurable.setdefault("hub_location", None)
                configurable.setdefault(
                    "awaiting_hub_location", configurable.get("hub_location") is None
                )
                configurable.setdefault("asst_thread_id", None)
                logger.info(f"Loaded conversation state for user {user_name} from legacy format")
                return stored_state

            logger.info(f"No existing conversation state found for user {user_name}, using default")
            return default_state
        except Exception as exc:
            logger.error(f"Failed to load conversation state for user {user_name}: {exc}")
            return default_state

    async def save_conversation_state(
        self, user_name: str, conversation_state: dict, context: Optional[TurnContext] = None
    ):
        await self._initialize(context)

        if not self.blob_storage:
            logger.debug(f"No blob storage available, skipping save for user {user_name}")
            return

        try:
            blob_key = self._get_date_based_blob_key(user_name)
            clean_state = {
                key: value
                for key, value in conversation_state.items()
                if key not in {"e_tag", "etag", "_etag", "__etag"}
            }
            await self.blob_storage.write({blob_key: clean_state})
            logger.info(f"Saved conversation state for user {user_name} in date folder")
        except Exception as exc:
            logger.error(f"Failed to save conversation state for user {user_name}: {exc}")


def get_conversation_key(context: TurnContext) -> tuple[str, str]:
    user_id = context.activity.from_property.id if context.activity.from_property else "unknown_user"
    conversation_id = (
        context.activity.conversation.id if context.activity.conversation else "unknown_conversation"
    )

    user_id = user_id.replace("|", "_").replace("/", "_").replace("\\", "_")
    conversation_id = conversation_id.replace("|", "_").replace("/", "_").replace("\\", "_")

    return user_id, conversation_id


async def check_blob_storage_access(context: TurnContext) -> bool:
    try:
        storage_account = config.az_blob_storage_account_name
        subscription_id = config.az_subscription_id
        resource_group = config.az_storage_rg_name or config.az_storage_rg

        if not all([storage_account, subscription_id, resource_group]):
            logger.warning("Missing required Azure configuration for blob storage access check")
            logger.warning(
                "Storage account: %s, Subscription: %s, RG: %s",
                storage_account,
                subscription_id,
                resource_group,
            )
            return True

        logger.debug("Checking blob storage public network access...")
        access_enabled = set_blob_account_public_access(
            storage_account,
            subscription_id,
            resource_group,
        )

        if not access_enabled:
            error_msg = (
                "Public network access is not enabled to the Storage Account. Please contact your administrator."
            )
            logger.error(error_msg)
            await context.send_activity(MessageFactory.text(error_msg))
            return False

        logger.debug("Blob storage public network access is enabled")
        return True
    except Exception as exc:
        logger.error(f"Error checking blob storage access: {exc}")
        error_msg = f"Error checking storage account access: {exc}. Please contact your administrator."
        await context.send_activity(MessageFactory.text(error_msg))
        return False


conversation_state_manager = ConversationStateManager()


def _ensure_assistants_thread(conversation_state: dict) -> Optional[str]:
    configurable = conversation_state.setdefault("configurable", {})
    existing_thread = configurable.get("asst_thread_id")
    if existing_thread:
        return existing_thread

    client = _get_sync_openai_client()
    if not client:
        logger.warning("Unable to create Assistants API thread because the Azure OpenAI client is unavailable")
        return None

    try:
        thread = client.beta.threads.create()
        configurable["asst_thread_id"] = thread.id
        logger.info("Created new Assistants API thread: %s", thread.id)
        return thread.id
    except Exception as exc:
        logger.error(f"Failed to create Assistants API thread: {exc}")
        return None


# Handle multi-line user messages that should route to the same handler while still
# ignoring slash-prefixed commands.
NON_COMMAND_MESSAGE_PATTERN = re.compile(r"^(?!/).*$", re.DOTALL)


@tag_app.message(NON_COMMAND_MESSAGE_PATTERN)
async def on_message(context: TurnContext, state: TurnState):
    try:
        user_message = context.activity.text or ""
        sender_name = (
            context.activity.from_property.name if context.activity.from_property else "EmulatorUser"
        )

        tenant_id = None
        try:
            if context.activity.conversation and hasattr(context.activity.conversation, "tenant_id"):
                tenant_id = context.activity.conversation.tenant_id
            elif context.activity.channel_data and "tenant" in context.activity.channel_data:
                tenant_id = context.activity.channel_data["tenant"].get("id")
        except Exception as exc:
            logger.warning(f"Could not extract tenant_id: {exc}")

        if tenant_id:
            if tenant_id == config.HOST_TENANT_ID:
                logger.info("User %s from HOST tenant: %s - authorized", sender_name, tenant_id)
            elif tenant_id == config.TENANT_ID:
                logger.info("User %s from GUEST tenant: %s - authorized", sender_name, tenant_id)
            else:
                logger.warning("User %s from unauthorized tenant: %s", sender_name, tenant_id)
                await context.send_activity(
                    MessageFactory.text("❌ **Access Denied**: Unauthorized tenant ID")
                )
                return
        else:
            logger.warning("No tenant ID found for user %s", sender_name)
            await context.send_activity(MessageFactory.text("❌ **Not Authorized**: No tenant ID found"))
            return

        user_name = sender_name
        logger.info("Processing message from user %s: %s", user_name, user_message)

        conversation_state = await conversation_state_manager.load_conversation_state(user_name, context)
        configurable_state = conversation_state.setdefault("configurable", {})
        configurable_state.setdefault("hub_location", None)
        configurable_state.setdefault(
            "awaiting_hub_location", configurable_state.get("hub_location") is None
        )

        detected_hub = _detect_hub_location(user_message)
        if detected_hub:
            previous_hub = configurable_state.get("hub_location")
            configurable_state["hub_location"] = detected_hub
            configurable_state["awaiting_hub_location"] = False
            if previous_hub and previous_hub != detected_hub:
                logger.info("Updated hub location from %s to %s", previous_hub, detected_hub)
            elif not previous_hub:
                logger.info("Captured hub location %s from user input", detected_hub)

        hub_location = configurable_state.get("hub_location")
        awaiting_hub_location = configurable_state.get("awaiting_hub_location", hub_location is None)

        if not hub_location:
            configurable_state["awaiting_hub_location"] = True
            available_hubs = ", ".join(sorted(KNOWN_HUBS.values())) if KNOWN_HUBS else "(please specify your hub)"
            hub_prompt = (
                "Before we get started, which Innovation Hub location are you working with today? "
                f"Supported hubs: {available_hubs}."
            )
            await context.send_activity(MessageFactory.text(hub_prompt))
            await conversation_state_manager.save_conversation_state(user_name, conversation_state, context)
            return
        elif awaiting_hub_location:
            configurable_state["awaiting_hub_location"] = False
            follow_up = (
                f"Thanks, {user_name}! Hub location set to {hub_location}. "
                "How can the TAB Agent help you today?"
            )
            await context.send_activity(MessageFactory.text(follow_up))
            await conversation_state_manager.save_conversation_state(user_name, conversation_state, context)
            return

        current_time = datetime.datetime.now(timezone.utc)
        last_timestamp = conversation_state["configurable"].get("last_message_timestamp")

        if last_timestamp:
            try:
                if isinstance(last_timestamp, str):
                    last_dt = datetime.datetime.fromisoformat(last_timestamp.replace("Z", "+00:00"))
                else:
                    last_dt = last_timestamp

                if (current_time - last_dt) > timedelta(minutes=10):
                    logger.info("Conversation stale (>10 minutes), resetting thread_id")
                    conversation_state["configurable"]["thread_id"] = None
                    conversation_state["configurable"]["asst_thread_id"] = None
            except Exception as exc:
                logger.error(f"Error parsing timestamp: {exc}")
                conversation_state["configurable"]["thread_id"] = None
                conversation_state["configurable"]["asst_thread_id"] = None

        conversation_state["configurable"]["last_message_timestamp"] = current_time.isoformat()

        user_id, conversation_id = get_conversation_key(context)
        logger.debug("Conversation context - user_id: %s, conversation_id: %s", user_id, conversation_id)

        if not await check_blob_storage_access(context):
            return

        if not user_message:
            welcome_msg = f"Hello {user_name}! How can I help you today?"
            await context.send_activity(MessageFactory.text(welcome_msg))
            await conversation_state_manager.save_conversation_state(user_name, conversation_state, context)
            return

        try:
            response = get_cvp_response(user_message, user_name, conversation_state)
            await context.send_activity(MessageFactory.text(response))
            await conversation_state_manager.save_conversation_state(user_name, conversation_state, context)
        except Exception as exc:
            logger.error(f"Error in CVP agent system: {exc}")
            logger.error(traceback.format_exc())
            error_msg = f"I encountered an error processing your request: {exc}"
            await context.send_activity(MessageFactory.text(error_msg))
            await conversation_state_manager.save_conversation_state(user_name, conversation_state, context)
    except Exception as exc:
        logger.error(f"Error in message handler: {exc}")
        await context.send_activity(
            MessageFactory.text("I encountered an error while processing your message. Please try again.")
        )


def get_cvp_response(user_input: str, user_name: str = "User", conversation_state: Optional[dict] = None) -> str:
    try:
        if conversation_state is None:
            conversation_state = {
                "configurable": {
                    "user_name": user_name,
                    "thread_id": str(uuid.uuid4()),
                    "asst_thread_id": None,
                    "hub_location": None,
                    "awaiting_hub_location": True,
                }
            }

        if "configurable" not in conversation_state:
            conversation_state["configurable"] = {}

        conversation_state["configurable"]["user_name"] = user_name
        conversation_state["configurable"].setdefault("hub_location", None)
        conversation_state["configurable"].setdefault(
            "awaiting_hub_location",
            conversation_state["configurable"].get("hub_location") is None,
        )
        conversation_state["configurable"].setdefault("asst_thread_id", None)

        if conversation_state["configurable"].get("thread_id") is None:
            l_graph_thread_id = str(uuid.uuid4())
            conversation_state["configurable"]["thread_id"] = l_graph_thread_id
            logger.info(f"Created new thread_id: {l_graph_thread_id}")

        if not conversation_state["configurable"].get("asst_thread_id"):
            asst_thread_id = _ensure_assistants_thread(conversation_state)
            if asst_thread_id:
                logger.info("Associated Assistants API thread %s with the conversation", asst_thread_id)
            else:
                logger.warning("Assistants API thread could not be created; downstream tools may fail")

        logger.info(
            "Processing user input for %s with thread_id: %s",
            user_name,
            conversation_state["configurable"].get("thread_id"),
        )

        response = _stream_graph_updates(user_input, graph_build.graph, conversation_state)
        return response
    except Exception as exc:
        error_details = traceback.format_exc()
        logger.error(f"Error in get_cvp_response: {exc}\n{error_details}")
        return "I encountered an error while processing your request. Please try again or contact support."


def _stream_graph_updates(user_input: str, graph, config_state) -> str:
    if not graph:
        raise ValueError("Graph is not initialized")

    try:
        result = graph.invoke({"messages": ("user", user_input)}, config=config_state)
        final_messages = result.get("messages") if isinstance(result, dict) else None

        if not final_messages:
            logger.warning("LangGraph did not return an assistant response; sending fallback message")
            return (
                "I'm ready to help with your Innovation Hub session. "
                "Please let me know what you need—meeting notes, agenda support, or document generation."
            )

        if isinstance(final_messages, list):
            for entry in reversed(final_messages):
                if hasattr(entry, "type") and entry.type in {"assistant", "ai"}:
                    content = getattr(entry, "content", None)
                elif isinstance(entry, dict) and entry.get("role") == "assistant":
                    content = entry.get("content")
                else:
                    continue

                if isinstance(content, str):
                    return content
                if isinstance(content, list):
                    combined = "\n".join(
                        part.get("text", "") for part in content if isinstance(part, dict)
                    )
                    if combined.strip():
                        return combined

        logger.warning("Assistant messages were present but no textual content could be extracted; using fallback")
        return (
            "I'm ready to help with your Innovation Hub session. "
            "Please let me know what you need—meeting notes, agenda support, or document generation."
        )
    except Exception as exc:
        logger.error(f"Error streaming graph updates: {exc}")
        raise


@tag_app.error
async def on_error(context: TurnContext, error: Exception):
    logger.error(f"Unhandled error: {error}")
    try:
        await context.send_activity(
            MessageFactory.text("Sorry, I encountered an unexpected error. Please try again.")
        )
    except Exception:
        pass


def main():
    """Entry point to start the aiohttp server with the configured agent."""

    start_server(
        agent_application=tag_app,
        auth_configuration=connection_manager.get_default_connection_configuration(),
    )


if __name__ == "__main__":
    main()

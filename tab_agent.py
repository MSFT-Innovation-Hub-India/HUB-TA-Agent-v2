from microsoft.agents.builder import ActivityHandler, MessageFactory, TurnContext
from microsoft.agents.core.models import ChannelAccount
from microsoft.agents.builder.state import UserState
from microsoft.agents.storage.memory_storage import MemoryStorage
from openai import AsyncAzureOpenAI
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from config import DefaultConfig
import datetime
from datetime import timezone, timedelta
import uuid
import traceback
import graph_build
from util.az_blob_account_access import set_blob_account_public_access


class TABAgent(ActivityHandler):
    def __init__(self, user_state: UserState, conversation_state):
        """
        Initialize the TAB Agent with user state and conversation state management.

        Args:
            user_state: UserState instance for managing user-specific data
            conversation_state: ConversationState/AgentState instance for managing conversation config
        """
        self.user_state = user_state
        self.conversation_state = conversation_state
        self.config = DefaultConfig()

        # Initialize Azure OpenAI client with managed identity
        token_provider = get_bearer_token_provider(
            DefaultAzureCredential(),
            "https://cognitiveservices.azure.com/.default",
        )
        self.openai_client = AsyncAzureOpenAI(
            azure_endpoint=self.config.az_openai_endpoint,
            azure_ad_token_provider=token_provider,
            api_version=self.config.az_openai_api_version,
        )
        print("INFO: Using managed identity for Azure OpenAI authentication")

        # Create state accessors
        self.user_profile_accessor = self.user_state.create_property("UserProfile")
        self.conversation_history_accessor = self.user_state.create_property(
            "ConversationHistory"
        )
        self.config_accessor = self.conversation_state.create_property("Config")
        self.timestamp_accessor = self.conversation_state.create_property(
            "LastMessageTimestamp"
        )

    async def on_message_activity(self, turn_context: TurnContext):
        

        """
        Handle incoming message activities with proper state management and thread_id freshness checking.
        """

        # First ensure public network access is enabled for the blob account before processing each request
        # Due to Secure Futures Initiative at Microsoft, the public network access is set to disabled for the blob account, daily.
        # All the Bot state is presently stored in the blob account, and the bot needs to access the blob account to store and retrieve the state data.
        flag = set_blob_account_public_access(
            self.config.az_storage_account_name,
            self.config.az_subscription_id,
            self.config.az_storage_rg_name,
        )
        if not flag:
            print(
                "DEBUG: Public network access is not enabled. Please contact your administrator."
            )
            await turn_context.send_activity(
                MessageFactory.text(
                    "Public network access is not enabled to the Storage Account. Please contact your administrator."
                )
            )
            return

        # Get user profile (create if doesn't exist)
        user_profile = await self.user_profile_accessor.get(
            turn_context,
            lambda: {
                "name": None,
                "conversation_count": 0,
                "city": None,
                "preferences": {},
                "agenda_flow_active": False,
                "waiting_for_meeting_notes": False,
            },
        )

        # Check if user is conversing from Microsoft Teams and auto-populate name
        if user_profile["name"] is None:
            # If the Microsoft Teams context is available, get the sender name from the Teams context
            try:
                if turn_context.activity.from_property and turn_context.activity.from_property.id:
                    # Check if this is a Teams channel
                    if turn_context.activity.channel_id == "msteams":
                        # Try to get member info from Teams
                        try:
                            # For Microsoft Agents SDK, we can try to access the member name directly
                            if hasattr(turn_context.activity.from_property, 'name') and turn_context.activity.from_property.name:
                                sender_name = turn_context.activity.from_property.name
                                user_profile["name"] = sender_name
                                print(f"DEBUG: {sender_name} has commenced a session with TAB from Microsoft Teams")
                            # Alternative: Try to get from channel data if available
                            elif (turn_context.activity.channel_data and 
                                  isinstance(turn_context.activity.channel_data, dict) and
                                  "tenant" in turn_context.activity.channel_data):
                                # This is Teams context, but we might need to extract name differently
                                print("DEBUG: Teams context detected but name extraction needs refinement")
                        except Exception as teams_error:
                            print(f"DEBUG: Error extracting Teams member info: {teams_error}")
            except Exception as e:
                print(f"DEBUG: Error getting member name from Teams context: {str(e)}")
                pass

        # Get conversation config (create if doesn't exist)
        conversation_config = await self.config_accessor.get(
            turn_context,
            lambda: {
                "configurable": {
                    "customer_name": None,
                    "thread_id": None,
                    "asst_thread_id": None,
                    "hub_location": None,
                }
            },
        )

        # Get conversation history (create if doesn't exist)
        conversation_history = await self.conversation_history_accessor.get(
            turn_context, lambda: []
        )

        # Get last message timestamp
        last_message_timestamp = await self.timestamp_accessor.get(
            turn_context, lambda: None
        )

        # Check timestamp freshness and reset thread_id if stale
        current_time = datetime.datetime.now(timezone.utc)
        if last_message_timestamp:
            # Convert string timestamp back to datetime for comparison
            try:
                if isinstance(last_message_timestamp, str):
                    last_dt = datetime.datetime.fromisoformat(
                        last_message_timestamp.replace("Z", "+00:00")
                    )
                else:
                    last_dt = last_message_timestamp

                print(
                    f"DEBUG - Current time: {current_time}, Last message time: {last_dt}"
                )

                if (current_time - last_dt) > timedelta(minutes=10):
                    print(
                        "DEBUG - Timestamp is older than 10 minutes, resetting conversation data."
                    )
                    conversation_config["configurable"]["thread_id"] = None
                    conversation_config["configurable"]["asst_thread_id"] = None
                    # Reset agenda flow state
                    user_profile["agenda_flow_active"] = False
                    user_profile["waiting_for_meeting_notes"] = False
            except Exception as e:
                print(f"ERROR parsing timestamp: {e}")
                # Reset on error
                conversation_config["configurable"]["thread_id"] = None
                conversation_config["configurable"]["asst_thread_id"] = None

        # Update timestamp
        await self.timestamp_accessor.set(turn_context, current_time.isoformat())

        # Debug: Print current state
        print(f"DEBUG: Current user profile: {user_profile}")
        print(f"DEBUG: Current conversation config: {conversation_config}")
        print(
            f"DEBUG: Current conversation history length: {len(conversation_history)}"
        )

        # Increment conversation count
        user_profile["conversation_count"] += 1

        # Get user message
        user_message = turn_context.activity.text

        # Add user message to conversation history with string timestamp
        current_time_str = current_time.isoformat()
        conversation_history.append(
            {"role": "user", "content": user_message, "timestamp": current_time_str}
        )

        # Check for special commands first
        if await self._clear_state_if_needed(turn_context):
            return

        # Handle different flow states
        agent_response = None

        # Priority 1: Check if name is known but city is missing - ask for city regardless of user message
        if user_profile.get("name") is not None and user_profile.get("city") is None:
            # Ensure customer_name is set in config
            if conversation_config["configurable"].get("customer_name") is None:
                conversation_config["configurable"]["customer_name"] = user_profile["name"]
            
            # Validate city with GPT-4o only if user message looks like a city
            # Otherwise, just ask for the city
            city_keywords = ["city", "hub", "location", "bangalore", "bengaluru", "atlanta", "boston", "chicago", "dallas", "detroit", "houston", "irvine", "minneapolis", "new york", "philadelphia", "seattle", "silicon valley", "st. louis", "toronto", "washington", "mexico city", "sao paulo", "amsterdam", "brussels", "copenhagen", "dubai", "herzliya", "istanbul", "london", "johannesburg", "milan", "munich", "oslo", "paris", "stockholm", "warsaw", "zurich", "beijing", "seoul", "shanghai", "singapore", "sydney", "taipei", "tokyo"]
            
            if any(keyword in user_message.lower() for keyword in city_keywords):
                matched_city = await self._validate_city_with_gpt(user_message)
                if matched_city:
                    user_profile["city"] = matched_city
                    # Also update the config with hub_location
                    conversation_config["configurable"]["hub_location"] = matched_city
                    agent_response = f"Thanks! I've set your Innovation Hub location to {matched_city}.\n\nWould you like to prepare an agenda for an Innovation Hub session? If yes, please provide your meeting notes starting with '### Internal Briefing Notes ###' or '### External Briefing Notes ###'."
                    user_profile["waiting_for_meeting_notes"] = True
                else:
                    agent_response = f"I couldn't find that city in our list of Innovation Hub locations. Please provide a valid Innovation Hub location from this list: {self.config.hub_cities}"
            else:
                # Ignore user message and ask for city
                agent_response = f"Before we get started, {user_profile['name']}, which Innovation Hub city are you associated with? Here are the available cities:\n\n{self.config.hub_cities.replace(', ', ', ')}"

        # Priority 2: Check if user is providing meeting notes for agenda creation
        elif user_profile.get("waiting_for_meeting_notes", False) and (
            "### Internal Briefing Notes ###" in user_message
            or "### External Briefing Notes ###" in user_message
            or "briefing" in user_message.lower()
            or "meeting notes" in user_message.lower()
        ):
            # User provided meeting notes - switch to LangGraph agent system
            agent_response = await self._handle_agenda_creation_flow(
                user_message, conversation_config, turn_context
            )
            user_profile["waiting_for_meeting_notes"] = False
            user_profile["agenda_flow_active"] = True

        # Priority 3: Handle name setting for non-Teams channels (when name is None)
        elif user_profile.get("name") is None:
            # Only set name from user input if Teams didn't already populate it
            user_profile["name"] = user_message.strip()
            # Also update the config with customer_name
            conversation_config["configurable"]["customer_name"] = user_message.strip()
            agent_response = f"Nice to meet you, {user_profile['name']}! Which Innovation Hub city are you associated with? Here are the available cities:\n\n{self.config.hub_cities.replace(', ', ', ')}"

        elif user_profile.get("agenda_flow_active", False):
            # User is in the middle of agenda creation flow - use LangGraph
            agent_response = await self._handle_agenda_creation_flow(
                user_message, conversation_config, turn_context
            )

        else:
            # For all other interactions, use the LangGraph system for intelligent responses
            # This provides consistent, context-aware responses powered by LLM
            if user_profile.get("name") and user_profile.get("city"):
                # User is fully set up, route to LangGraph for intelligent conversation
                agent_response = await self._handle_agenda_creation_flow(
                    user_message, conversation_config, turn_context
                )
                # If this was an agenda-related request, mark the flow as active
                if any(
                    phrase in user_message.lower()
                    for phrase in [
                        "agenda",
                        "prepare agenda",
                        "innovation hub session",
                        "meeting",
                        "briefing",
                    ]
                ):
                    user_profile["agenda_flow_active"] = True
            else:
                # Handle agenda preparation request for users not fully set up
                if any(
                    phrase in user_message.lower()
                    for phrase in [
                        "agenda",
                        "prepare agenda",
                        "innovation hub session",
                        "meeting",
                    ]
                ):
                    if user_profile.get("city"):
                        agent_response = "I can help you prepare an agenda for your Innovation Hub session. Please provide your meeting notes starting with '### Internal Briefing Notes ###' or '### External Briefing Notes ###'."
                        user_profile["waiting_for_meeting_notes"] = True
                    else:
                        agent_response = f"To prepare an agenda, I first need to know which Innovation Hub city you're associated with. Please choose from: {self.config.hub_cities.replace(', ', ', ')}"
                else:
                    # For general conversation when user isn't fully set up, provide a helpful response
                    agent_response = f"I understand you said: '{user_message}'. I'm here to help you prepare agendas for Innovation Hub sessions. How can I assist you?"

        # Add agent response to conversation history with string timestamp
        conversation_history.append(
            {
                "role": "assistant",
                "content": agent_response,
                "timestamp": current_time_str,
            }
        )

        # Limit conversation history to last 20 exchanges to prevent memory issues
        if len(conversation_history) > 40:  # 40 = 20 exchanges (user + assistant)
            conversation_history = conversation_history[-40:]

        # Save updated state using accessors
        await self.user_profile_accessor.set(turn_context, user_profile)
        await self.conversation_history_accessor.set(turn_context, conversation_history)
        await self.config_accessor.set(turn_context, conversation_config)

        # Explicitly save changes to both storage states
        await self.user_state.save_changes(turn_context)
        await self.conversation_state.save_changes(turn_context)

        # Debug: Print state after saving
        print(f"DEBUG: Saved user profile: {user_profile}")
        print(f"DEBUG: Saved conversation config: {conversation_config}")
        print(f"DEBUG: Saved conversation history length: {len(conversation_history)}")

        # Send response back to user
        await turn_context.send_activity(MessageFactory.text(agent_response))

    async def on_members_added_activity(
        self, members_added: list[ChannelAccount], turn_context: TurnContext
    ):
        """
        Handle when new members are added to the conversation.
        """
        user_profile = await self.user_profile_accessor.get(
            turn_context,
            lambda: {
                "name": None,
                "conversation_count": 0,
                "city": None,
                "preferences": {},
                "agenda_flow_active": False,
                "waiting_for_meeting_notes": False,
            },
        )

        for member in members_added:
            if member.id != turn_context.activity.recipient.id:
                welcome_message = "Hello and welcome!"
                if user_profile.get("name") and user_profile.get("city"):
                    welcome_message = f"Welcome back, {user_profile['name']} from {user_profile['city']} Innovation Hub! Would you like to prepare an agenda for an Innovation Hub session?"
                elif user_profile.get("name"):
                    welcome_message = f"Welcome back, {user_profile['name']}! Which Innovation Hub city are you associated with? Here are the available cities:\n\n{self.config.hub_cities.replace(', ', ', ')}"
                elif user_profile["conversation_count"] == 0:
                    # Check if this is Teams and try to auto-detect name
                    if turn_context.activity.channel_id == "msteams":
                        welcome_message = "Hello! I'm your TAB (Technical Architect Buddy) Agent. I can help you prepare agendas for Innovation Hub sessions. Which Innovation Hub city are you associated with?"
                    else:
                        welcome_message = "Hello! I'm your TAB (Technical Architect Buddy) Agent. I can help you prepare agendas for Innovation Hub sessions. What's your name?"

                await turn_context.send_activity(MessageFactory.text(welcome_message))

    async def _validate_city_with_gpt(self, user_input: str) -> str:
        """
        Validate and match user input to available Innovation Hub cities using GPT-4o.

        Args:
            user_input: User's input that should match a city

        Returns:
            Matched city name or None if no match found
        """
        print(f"DEBUG: Starting GPT validation for input: '{user_input}'")

        if not self.openai_client:
            print("ERROR: OpenAI client not initialized")
            return None

        try:
            # Create messages following your implementation pattern
            messages = [
                {
                    "role": "system",
                    "content": f'You are a city validation assistant. Based on the user input identify the match from the list of valid Innovation Hub location cities: {self.config.hub_cities}. Return a JSON response in the format {{"city": "matched_city_name"}} or {{"city": null}} if no match. Use your knowledge of the cities to validate the user input, even if the user provides synonyms for the city names.',
                },
                {
                    "role": "user",
                    "content": f"Is '{user_input}' a valid city in this list: {self.config.hub_cities}?",
                },
            ]

            print(
                f"DEBUG: Making GPT call with model: {self.config.az_deployment_name}"
            )

            # Get the validation from Azure OpenAI
            response = await self.openai_client.chat.completions.create(
                model=self.config.az_deployment_name,
                messages=messages,
                response_format={"type": "json_object"},
            )

            # Parse the JSON response
            import json

            result = json.loads(response.choices[0].message.content)
            print("DEBUG - Validation result:", result)
            matched_city = result.get("city")

            if matched_city:
                print(f"DEBUG: GPT matched '{user_input}' to '{matched_city}'")
                return matched_city
            else:
                print(f"DEBUG: GPT found no match for '{user_input}'")
                return None

        except Exception as e:
            print(f"ERROR: GPT city validation failed: {e}")
            import traceback

            traceback.print_exc()
            return None

    async def _clear_state_if_needed(self, turn_context: TurnContext):
        """
        Utility method to clear state if needed (for debugging or reset functionality).
        """
        user_message = turn_context.activity.text.lower()
        if "reset" in user_message or "clear state" in user_message:
            await self.user_profile_accessor.delete(turn_context)
            await self.conversation_history_accessor.delete(turn_context)
            await self.config_accessor.delete(turn_context)
            await self.timestamp_accessor.delete(turn_context)
            await turn_context.send_activity(
                MessageFactory.text("State cleared! Starting fresh.")
            )
            return True
        return False

    async def _handle_agenda_creation_flow(
        self, user_input: str, conversation_config: dict, turn_context: TurnContext
    ) -> str:
        """
        Handle the agenda creation flow using the LangGraph system from graph_build.py

        Args:
            user_input: User's input (meeting notes or responses)
            conversation_config: Current conversation configuration
            turn_context: Bot framework turn context

        Returns:
            Response from the LangGraph agent system
        """
        try:
            # Initialize thread_id if not exists
            if conversation_config["configurable"]["thread_id"] is None:
                # Create a new thread ID for LangGraph
                l_graph_thread_id = str(uuid.uuid4())

                # Create a proper OpenAI thread for the Assistants API
                try:
                    openai_thread = await self.openai_client.beta.threads.create()
                    l_asst_thread_id = openai_thread.id
                    print(f"DEBUG: Created new OpenAI thread: {l_asst_thread_id}")
                except Exception as openai_error:
                    print(f"ERROR: Failed to create OpenAI thread: {openai_error}")
                    # Fallback to a mock thread ID format that won't cause errors
                    l_asst_thread_id = f"thread_{str(uuid.uuid4())}"
                    print(f"DEBUG: Using fallback thread ID: {l_asst_thread_id}")

                # Update configuration for the user session to bootstrap the multi-agent system
                conversation_config["configurable"]["thread_id"] = l_graph_thread_id
                conversation_config["configurable"]["asst_thread_id"] = l_asst_thread_id

                print(f"DEBUG: Created new thread_id: {l_graph_thread_id}")
                print(f"DEBUG: Created new asst_thread_id: {l_asst_thread_id}")
                print(
                    f"DEBUG: User name: {conversation_config['configurable']['customer_name']}"
                )

            # Use the graph to process the user input and get response
            response = self._stream_graph_updates(
                user_input, graph_build.graph, conversation_config
            )
            return response

        except Exception as e:
            error_details = traceback.format_exc()
            print(
                f"ERROR: Error in _handle_agenda_creation_flow: {str(e)}\n{error_details}"
            )
            return "I encountered an error while processing your request. Please try again or contact support."

    def _stream_graph_updates(self, user_input: str, graph, config) -> str:
        """
        Stream graph updates and return the final response.
        This is based on the implementation from your reference code.

        Args:
            user_input: User's input message
            graph: The LangGraph instance
            config: Configuration for the graph execution

        Returns:
            Final response from the graph execution
        """
        try:
            events = graph.stream(
                {"messages": [("user", user_input)]},
                config=config,
                subgraphs=True,
                stream_mode=None,
            )

            l_events = list(events)

            if not l_events:
                return "No response received from the agenda creation system."

            msg = list(l_events[-1])

            # Debug logging for development
            print(f"DEBUG - Last message structure: {msg[-1]}")

            def extract_content(obj):
                """Recursively search for AIMessage content in nested structure"""
                if hasattr(obj, "content"):
                    return obj.content

                if isinstance(obj, dict):
                    for value in obj.values():
                        content = extract_content(value)
                        if content:
                            return content

                if isinstance(obj, (list, tuple)):
                    for item in obj:
                        content = extract_content(item)
                        if content:
                            return content

                return None

            # Try to extract content from the message
            if isinstance(msg[-1], dict):
                content = extract_content(msg[-1])
                if content:
                    return content

            # Fallback to string representation if no content found
            return str(msg[-1])

        except Exception as e:
            error_details = traceback.format_exc()
            print(f"ERROR - Error in stream_graph_updates: {str(e)}\n{error_details}")
            return "Error in processing the agenda creation request. Please contact TAB support."

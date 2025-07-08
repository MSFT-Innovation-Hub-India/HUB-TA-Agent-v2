from microsoft.agents.builder import ActivityHandler, MessageFactory, TurnContext
from microsoft.agents.core.models import ChannelAccount
from microsoft.agents.builder.state import UserState
from microsoft.agents.storage.memory_storage import MemoryStorage 
from openai import AsyncAzureOpenAI
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from config import DefaultConfig

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
            azure_endpoint=self.config.AZURE_OPENAI_ENDPOINT,
            azure_ad_token_provider=token_provider,
            api_version=self.config.AZURE_OPENAI_API_VERSION
        )
        print("INFO: Using managed identity for Azure OpenAI authentication")
        
        # Create state accessors
        self.user_profile_accessor = self.user_state.create_property("UserProfile")
        self.conversation_history_accessor = self.user_state.create_property("ConversationHistory")
        self.config_accessor = self.conversation_state.create_property("Config")

    async def on_message_activity(self, turn_context: TurnContext):
        """
        Handle incoming message activities with proper state management.
        """
        
        # Get user profile (create if doesn't exist)
        user_profile = await self.user_profile_accessor.get(turn_context, lambda: {
            "name": None,
            "conversation_count": 0,
            "city": None,
            "preferences": {}
        })
        
        # Get conversation config (create if doesn't exist)
        conversation_config = await self.config_accessor.get(turn_context, lambda: {
            "configurable": {
                "customer_name": None,
                "thread_id": None,
                "asst_thread_id": None,
                "hub_location": None,
            }
        })
        
        # Get conversation history (create if doesn't exist)
        conversation_history = await self.conversation_history_accessor.get(turn_context, lambda: [])
        
        # Debug: Print current state
        print(f"DEBUG: Current user profile: {user_profile}")
        print(f"DEBUG: Current conversation config: {conversation_config}")
        print(f"DEBUG: Current conversation history length: {len(conversation_history)}")
        
        # Increment conversation count
        user_profile["conversation_count"] += 1
        
        # Get user message
        user_message = turn_context.activity.text
        
        # Add user message to conversation history with string timestamp
        import datetime
        current_time = datetime.datetime.now().isoformat()
        conversation_history.append({
            "role": "user", 
            "content": user_message,
            "timestamp": current_time
        })
        
        # Check for special commands first
        if await self._clear_state_if_needed(turn_context):
            return
            
        # Handle name and city setting logic before generating response
        if user_profile.get("name") is None and not any(word in user_message.lower() for word in ["hello", "hi", "hey"]):
            user_profile["name"] = user_message.strip()
            # Also update the config with customer_name
            conversation_config["configurable"]["customer_name"] = user_message.strip()
            agent_response = f"Nice to meet you, {user_profile['name']}! Which Innovation Hub city are you associated with? Here are the available cities:\n\n{self.config.HUB_CITIES.replace(', ', ', ')}"
        elif user_profile.get("name") is not None and user_profile.get("city") is None:
            # Validate city with GPT-4o
            matched_city = await self._validate_city_with_gpt(user_message)
            if matched_city:
                user_profile["city"] = matched_city
                # Also update the config with hub_location
                conversation_config["configurable"]["hub_location"] = matched_city
                agent_response = f"Thanks! I've set your Innovation Hub location to {matched_city}. How can I help you today?"
            else:
                agent_response = f"I couldn't find that city in our list of Innovation Hub locations. Please provide a valid Innovation Hub location from this list: {self.config.HUB_CITIES}"
        else:
            # Generate agent response (replace with your actual agent logic)
            agent_response = await self._generate_response(user_message, user_profile, conversation_history)
        
        # Add agent response to conversation history with string timestamp
        conversation_history.append({
            "role": "assistant", 
            "content": agent_response,
            "timestamp": current_time
        })
        
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

    async def on_members_added_activity(self, members_added: list[ChannelAccount], turn_context: TurnContext):
        """
        Handle when new members are added to the conversation.
        """
        user_profile = await self.user_profile_accessor.get(turn_context, lambda: {
            "name": None,
            "conversation_count": 0,
            "city": None,
            "preferences": {}
        })
        
        for member in members_added:
            if member.id != turn_context.activity.recipient.id:
                welcome_message = "Hello and welcome!"
                if user_profile.get("name") and user_profile.get("city"):
                    welcome_message = f"Welcome back, {user_profile['name']} from {user_profile['city']} Innovation Hub!"
                elif user_profile.get("name"):
                    welcome_message = f"Welcome back, {user_profile['name']}!"
                elif user_profile["conversation_count"] == 0:
                    welcome_message = "Hello! I'm your TAB Agent. What's your name?"
                
                await turn_context.send_activity(MessageFactory.text(welcome_message))

    async def _generate_response(self, user_message: str, user_profile: dict, conversation_history: list) -> str:
        """
        Generate a response based on user message, profile, and conversation history.
        Replace this with your actual agent logic.
        
        Args:
            user_message: The current user message
            user_profile: User's profile data
            conversation_history: List of previous conversation exchanges
            
        Returns:
            Generated response string
        """
        # Simple response logic - replace with your actual agent implementation
        message_lower = user_message.lower()
        
        # Handle greetings
        if any(greeting in message_lower for greeting in ["hello", "hi", "hey"]):
            if user_profile.get("name"):
                return f"Hello {user_profile['name']}! How can I assist you today?"
            else:
                return "Hello! What's your name?"
        
        # Handle conversation count inquiry
        if "how many" in message_lower and "message" in message_lower:
            return f"We've exchanged {user_profile['conversation_count']} messages so far!"
        
        # Handle conversation history inquiry
        if "history" in message_lower or "previous" in message_lower:
            if len(conversation_history) > 2:  # More than just the current exchange
                return f"We've been talking about: {', '.join([msg['content'][:30] + '...' for msg in conversation_history[-6:-1] if msg['role'] == 'user'])}"
            else:
                return "This is the beginning of our conversation!"
        
        # Handle joke requests
        if "joke" in message_lower:
            return "Why don't scientists trust atoms? Because they make up everything! 😄"
        
        # Handle name inquiry
        if "my name" in message_lower or "what is my name" in message_lower:
            if user_profile.get("name"):
                return f"Your name is {user_profile['name']}!"
            else:
                return "I don't know your name yet. What should I call you?"
        
        # Handle city inquiry
        if "my city" in message_lower or "which city" in message_lower or "innovation hub" in message_lower:
            if user_profile.get("city"):
                return f"You're associated with the {user_profile['city']} Innovation Hub!"
            else:
                return f"I don't know which Innovation Hub city you're associated with yet. Please choose from: {self.config.HUB_CITIES.replace(', ', ', ')}"
        
        # Handle profile inquiry
        if "my profile" in message_lower or "my information" in message_lower:
            profile_info = f"Here's your profile:\n- Name: {user_profile.get('name', 'Not set')}\n- Innovation Hub City: {user_profile.get('city', 'Not set')}\n- Messages exchanged: {user_profile.get('conversation_count', 0)}"
            return profile_info
        
        # Default response
        return f"I understand you said: '{user_message}'. How can I help you further?"

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
                    "content": f'You are a city validation assistant. Based on the user input identify the match from the list of valid Innovation Hub location cities: {self.config.HUB_CITIES}. Return a JSON response in the format {{"city": "matched_city_name"}} or {{"city": null}} if no match. Use your knowledge of the cities to validate the user input, even if the user provides synonyms for the city names.',
                },
                {
                    "role": "user",
                    "content": f"Is '{user_input}' a valid city in this list: {self.config.HUB_CITIES}?",
                },
            ]

            print(f"DEBUG: Making GPT call with model: {self.config.AZURE_OPENAI_DEPLOYMENT}")
            
            # Get the validation from Azure OpenAI
            response = await self.openai_client.chat.completions.create(
                model=self.config.AZURE_OPENAI_DEPLOYMENT,
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

    def _simple_city_match(self, user_input: str) -> str:
        """
        Simple fallback city matching using string comparison.
        
        Args:
            user_input: User's input that should match a city
            
        Returns:
            Matched city name or None if no match found
        """
        user_input_lower = user_input.lower().strip()
        available_cities = [city.strip() for city in self.config.HUB_CITIES.split(',')]
        
        # Try exact match first
        for city in available_cities:
            if city.lower() == user_input_lower:
                print(f"DEBUG: Simple exact match found: {city}")
                return city
        
        # Try partial match
        for city in available_cities:
            if user_input_lower in city.lower() or city.lower() in user_input_lower:
                print(f"DEBUG: Simple partial match found: {city}")
                return city
        
        # Try common abbreviations
        abbreviations = {
            "nyc": "New York",
            "sf": "Silicon Valley",
            "la": None,  # Not in our list
            "chi": "Chicago",
            "philly": "Philadelphia",
            "dc": "Washington"
        }
        
        if user_input_lower in abbreviations:
            match = abbreviations[user_input_lower]
            if match:
                print(f"DEBUG: Simple abbreviation match found: {match}")
                return match
        
        print(f"DEBUG: No simple match found for: {user_input}")
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
            await turn_context.send_activity(MessageFactory.text("State cleared! Starting fresh."))
            return True
        return False
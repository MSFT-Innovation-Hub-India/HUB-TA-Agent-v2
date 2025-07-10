# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

from aiohttp.web import Application, Request, Response, run_app
from dotenv import load_dotenv

from microsoft.agents.builder import RestChannelServiceClientFactory
from microsoft.agents.hosting.aiohttp import CloudAdapter, jwt_authorization_middleware
from microsoft.agents.authorization import (
    Connections,
    AccessTokenProviderBase,
    ClaimsIdentity,
)
from microsoft.agents.authentication.msal import MsalAuth
from microsoft.agents.storage.memory_storage import MemoryStorage 
from microsoft.agents.builder.state.user_state import UserState
from microsoft.agents.builder.state.agent_state import AgentState

from tab_agent import TABAgent
from config import DefaultConfig

load_dotenv()

AUTH_PROVIDER = MsalAuth(DefaultConfig())

class DefaultConnection(Connections):
    def get_default_connection(self) -> AccessTokenProviderBase:
        pass

    def get_token_provider(
        self, claims_identity: ClaimsIdentity, service_url: str
    ) -> AccessTokenProviderBase:
        return AUTH_PROVIDER

    def get_connection(self, connection_name: str) -> AccessTokenProviderBase:
        pass

CONFIG = DefaultConfig()
CHANNEL_CLIENT_FACTORY = RestChannelServiceClientFactory(CONFIG, DefaultConnection())

# Set up in-memory storage (replace with your desired Storage for production)
storage = MemoryStorage()

# Create user state and conversation state
user_state = UserState(storage)
conversation_state = UserState(storage)  # Using UserState for conversation config

# Create adapter
ADAPTER = CloudAdapter(CHANNEL_CLIENT_FACTORY)

# Create the Agent with state management
AGENT = TABAgent(user_state, conversation_state)

# Listen for incoming requests on /api/messages
async def messages(req: Request) -> Response:
    adapter: CloudAdapter = req.app["adapter"]
    return await adapter.process(req, AGENT)

# Health check endpoint for monitoring
# async def health_check(req: Request) -> Response:
#     return Response(text="OK", status=200)

APP = Application(middlewares=[jwt_authorization_middleware])
APP.router.add_post("/api/messages", messages)
# APP.router.add_get("/health", health_check)
APP["agent_configuration"] = CONFIG
APP["adapter"] = ADAPTER

if __name__ == "__main__":
    try:
        # Use 0.0.0.0 to accept connections from any interface (required for containers)
        run_app(APP, host="0.0.0.0", port=3978)
    except Exception as error:
        print("Error starting the application: check the  logs too!", error)
        raise error
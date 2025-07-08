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

# Create adapter.
ADAPTER = CloudAdapter(CHANNEL_CLIENT_FACTORY)

# Create the Agent
AGENT = TABAgent()


# Listen for incoming requests on /api/messages
async def messages(req: Request) -> Response:
    adapter: CloudAdapter = req.app["adapter"]
    return await adapter.process(req, AGENT)


APP = Application(middlewares=[jwt_authorization_middleware])
APP.router.add_post("/api/messages", messages)
APP["agent_configuration"] = CONFIG
APP["adapter"] = ADAPTER

if __name__ == "__main__":
    try:
        run_app(APP, host="localhost", port=CONFIG.PORT)
    except Exception as error:
        raise error

...
# if __name__ == "__main__":
#     # ACA injects PORT when ingress is enabled; fall back to 3978 locally
#     port = int(os.getenv("PORT", 3978))

#     # Bind to 0.0.0.0 so Envoy can reach the process
#     run_app(APP, host="0.0.0.0", port=port)
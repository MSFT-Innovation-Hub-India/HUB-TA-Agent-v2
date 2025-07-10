# Technical Architect Buddy (TAB) for Innovation Hub - M365 Agents SDK

## Overview
TAB is an AI-powered conversational agent built with the **Microsoft 365 Agents SDK** that helps Technical Architects at Microsoft Innovation Hub prepare for customer engagements. It provides an interactive chat experience through Microsoft Teams to automate the process of extracting key information from meeting notes, creating structured agendas, and generating professional Microsoft Word documents for Innovation Hub sessions.

## Features
- **Interactive Chat Interface**: Built as a Microsoft 365 conversational agent accessible through Teams and other channels
- **Meeting Notes Analysis**: Extracts metadata and agenda goals from internal and external meeting notes via natural conversation
- **Agenda Creation**: Generates detailed agendas based on extracted information and customer requirements
- **Document Generation**: Creates formatted Microsoft Word (.docx) documents ready for customer presentations
- **Speaker Matching**: Automatically assigns appropriate speakers from the Innovation Hub team based on topics
- **State Management**: Maintains conversation context and user preferences across sessions
- **Multi-Hub Support**: Generic implementation supporting multiple Innovation Hub locations through configuration

## Technology Stack
This implementation leverages the **Microsoft 365 Agents SDK** with the following architecture:
- **Microsoft 365 Agents SDK**: Core conversational AI framework
- **Azure OpenAI**: LLM integration with managed identity authentication
- **LangGraph**: Multi-agent workflow orchestration
- **Azure Blob Storage**: Document and state persistence
- **Azure Container Apps**: Cloud deployment platform
- **aiohttp**: Asynchronous web framework for hosting

## System Architecture
The application uses a conversational agent approach with multiple specialized components:
- **TABAgent**: Main conversational agent handling Microsoft Teams interactions
- **Notes Extractor Agent**: Extracts and validates metadata and goals from meeting notes
- **Agenda Creator Agent**: Generates structured agendas based on extracted information  
- **Document Generator Agent**: Creates and formats Word documents with the agenda
- **State Management**: Manages user state and conversation context using Microsoft 365 Agents SDK state management

## Prerequisites
- Python 3.12+
- Azure OpenAI Service with GPT-4 deployment
- Azure Blob Storage account
- Azure Application Insights (optional, for logging)
- Azure Container Apps (for deployment)
- Microsoft App Registration for bot authentication
- Microsoft 365 Agents SDK (pre-release)

## Setup Instructions
1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd tab-agent-bot
   ```

2. **Install dependencies**
   ```bash
   pip install -r requirements.txt
   ```

3. **Configure environment variables**
   - Copy `.example-env` to `.env` and configure with your Azure service details
   - Required environment variables:
     - `TENANT_ID`: Azure AD tenant ID
     - `CLIENT_ID`: Azure App Registration client ID
     - `CLIENT_SECRET`: Azure App Registration client secret
     - `az_openai_endpoint`: Azure OpenAI endpoint
     - `az_deployment_name`: Azure OpenAI GPT-4 deployment name
     - `az_openai_api_version`: Azure OpenAI API version
     - `az_blob_storage_account_name`: Azure Blob Storage account name
     - `hub_cities`: Comma-separated list of supported hub cities

4. **Run locally for development**
   ```bash
   python app.py
   ```

5. **Deploy to Azure Container Apps**
   - Build and push container image
   - Configure Azure Container Apps with environment variables
   - Set messaging endpoint in Azure Bot Service to: `https://<your-container-app-url>/api/messages`

## Workflow
1. **Start Conversation**: User initiates chat with TAB through Microsoft Teams
2. **Provide Meeting Notes**: User shares meeting notes (internal or external) through natural conversation
3. **Notes Analysis**: The Notes Extractor Agent identifies metadata and goals from the shared notes
4. **Agenda Generation**: The Agenda Creator Agent generates a structured agenda based on extracted information
5. **Document Creation**: The Document Generator Agent creates a formatted Word document
6. **Delivery**: The final document is saved to Azure Blob Storage and can be shared with the customer
7. **State Persistence**: Conversation state and user preferences are maintained across sessions

## Configuration
Key configuration parameters are set in [`config.py`](config.py) and include:
- **Authentication**: Azure AD tenant, client ID, and client secret
- **Azure OpenAI**: Endpoints, deployment names, and API versions  
- **Storage**: Azure Blob Storage account and container details
- **Logging**: Azure Application Insights configuration
- **Hub Settings**: Supported Innovation Hub cities and assistant configurations
- **Application**: Port settings and runtime configurations

## Key Files
- [`app.py`](app.py): Main application entry point using Microsoft 365 Agents SDK hosting
- [`tab_agent.py`](tab_agent.py): Core conversational agent implementation extending ActivityHandler
- [`config.py`](config.py): Configuration management with Azure service integration
- [`graph_build.py`](graph_build.py): LangGraph workflow orchestration for multi-agent interactions
- [`tools/agenda_selector.py`](tools/agenda_selector.py): Agenda generation logic and prompt templates
- [`tools/doc_generator.py`](tools/doc_generator.py): Microsoft Word document creation utilities
- [`tools/hub_master.py`](tools/hub_master.py): Hub-specific data and speaker management
- [`util/az_blob_storage.py`](util/az_blob_storage.py): Azure Blob Storage integration
- [`util/az_blob_account_access.py`](util/az_blob_account_access.py): Blob account access management
- [`input_files/hub-bengaluru.md`](input_files/hub-bengaluru.md): Hub-specific speaker and topic mappings
- [`Dockerfile`](Dockerfile): Container configuration for Azure Container Apps deployment

## Microsoft 365 Agents SDK Architecture

This implementation leverages the Microsoft 365 Agents SDK which provides:
- **ActivityHandler**: Base class for handling different types of activities (messages, member additions, etc.)
- **CloudAdapter**: Handles communication between the bot and Microsoft channels
- **State Management**: Built-in user state and conversation state management
- **Authentication**: Integrated MSAL authentication for Azure services
- **Hosting**: aiohttp-based hosting with JWT authorization middleware

### Key Components:

1. **TABAgent (ActivityHandler)**
   - Extends Microsoft 365 Agents SDK ActivityHandler
   - Manages conversation flow and user interactions
   - Integrates with Azure OpenAI using managed identity
   - Handles state persistence and retrieval

2. **State Management**
   - UserState: Tracks user preferences, conversation history, and session data
   - ConversationState: Manages conversation-specific configuration and context
   - MemoryStorage: In-memory storage for development (configurable for production)

3. **Authentication & Authorization**
   - MsalAuth: Microsoft Authentication Library integration
   - JWT middleware: Validates incoming requests from Microsoft channels
   - Managed Identity: Secure authentication to Azure OpenAI and other services

4. **Multi-Agent Workflow (LangGraph)**
   - Orchestrates specialized agents for different tasks
   - Maintains workflow state across agent interactions
   - Enables complex document generation pipelines

## Deployment Architecture

The application is deployed on **Azure Container Apps** with:
- Container listening on `0.0.0.0:3978` for external connectivity
- Health check endpoint at `/health` for monitoring
- Message endpoint at `/api/messages` for bot communication
- Environment-based configuration for different deployment stages
- Managed identity integration for secure Azure service access

## Usage

1. **Add the bot to Microsoft Teams** using the Azure Bot Service registration
2. **Start a conversation** with TAB in Teams
3. **Provide meeting notes** by typing or pasting them in the chat
4. **Follow the conversational flow** as TAB guides you through:
   - Notes extraction and validation
   - Agenda goal identification
   - Speaker assignments
   - Document generation
5. **Receive the generated agenda document** via Azure Blob Storage link

## Development Notes

- Built with **Microsoft 365 Agents SDK** (pre-release version 0.0.0a3)
- Uses **LangGraph** for multi-agent workflow orchestration
- Implements **Azure managed identity** for secure service authentication
- Supports **containerized deployment** on Azure Container Apps
- Maintains **conversation state** across multiple interactions
- Includes **health monitoring** and logging capabilities

## Troubleshooting

### Common Issues:
1. **Connection errors**: Ensure the container is listening on `0.0.0.0:3978`, not `localhost:3978`
2. **Authentication failures**: Verify Azure AD app registration and managed identity configuration
3. **Blob storage access**: Check that public network access is enabled on the storage account
4. **OpenAI errors**: Confirm Azure OpenAI deployment name and endpoint configuration

### Health Check:
Visit `https://<your-container-app-url>/health` to verify the service is running and responsive.

## License
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the MIT License.
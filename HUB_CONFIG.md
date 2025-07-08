# Hub-Specific Assistant File ID Configuration

## Overview

The application now supports hub-specific assistant file IDs to allow different Azure OpenAI Assistant configurations for different innovation hub locations.

## Configuration

### Environment Variable Format

Add the following to your `.env` file:

```env
# Hub-specific Assistant File IDs (JSON format)
hub_assistant_file_ids={"bengaluru": "assistant-CM47Ev6uB3u5G4T3wCtMYW", "mumbai": "assistant-XXXXXXXXXXXXXXXXXXXX", "delhi": "assistant-YYYYYYYYYYYYYYYYYYYY", "chennai": "assistant-ZZZZZZZZZZZZZZZZZZZZ", "hyderabad": "assistant-AAAAAAAAAAAAAAAAAAAAA"}
```

### JSON Structure

The `hub_assistant_file_ids` environment variable should contain a JSON object where:
- **Keys**: Normalized hub names (lowercase, no spaces or special characters)
- **Values**: Corresponding Azure OpenAI Assistant file IDs

### Hub Name Normalization

Hub names are automatically normalized using the following rules:
- Convert to lowercase
- Remove all spaces and special characters
- Keep only alphanumeric characters

**Examples:**
- "Bengaluru" → "bengaluru"
- "New Delhi" → "newdelhi" 
- "MUMBAI" → "mumbai"
- "Chennai!" → "chennai"

## Usage

### In Code

```python
from config import DefaultConfig

config = DefaultConfig()

# Get file ID for a specific hub
file_id = config.get_hub_assistant_file_id("Bengaluru")
# Returns: "assistant-CM47Ev6uB3u5G4T3wCtMYW"

# Hub names are case-insensitive and handle spaces
file_id = config.get_hub_assistant_file_id("new delhi")
# Returns: file ID for "newdelhi" if configured

# Get normalized hub name
normalized = config.normalize_hub_name("New Delhi")
# Returns: "newdelhi"
```

### As a LangGraph Tool

```python
from tools.hub_master import get_hub_assistant_file_id

# Use in LangGraph with RunnableConfig
config = {"configurable": {"hub_location": "Bengaluru"}}
file_id = get_hub_assistant_file_id(config)
```

## Configuration Best Practices

### 1. Use Descriptive Keys
Use the most common/official name for each hub location as the key:

```json
{
  "bengaluru": "assistant-...",
  "mumbai": "assistant-...",
  "delhi": "assistant-...",
  "chennai": "assistant-...",
  "hyderabad": "assistant-..."
}
```

### 2. Handle Alternative Names
For cities with multiple common names, you can add multiple entries:

```json
{
  "bengaluru": "assistant-CM47Ev6uB3u5G4T3wCtMYW",
  "bangalore": "assistant-CM47Ev6uB3u5G4T3wCtMYW",
  "delhi": "assistant-YYYYYYYYYYYYYYYYYYYY",
  "newdelhi": "assistant-YYYYYYYYYYYYYYYYYYYY"
}
```

### 3. Validation
Use the test script to validate your configuration:

```bash
python test_hub_config.py
```

## Error Handling

- If no file ID is found for a hub, a warning is logged and `None` is returned
- The application falls back to the default assistant configuration
- Invalid JSON in the environment variable is handled gracefully with warnings

## Backward Compatibility

The legacy `file_ids` environment variable is still supported for backward compatibility, but the new hub-specific configuration is recommended for multi-hub deployments.

## Migration Guide

### From Single File ID to Hub-Specific

**Old Configuration:**
```env
file_ids=assistant-CM47Ev6uB3u5G4T3wCtMYW
```

**New Configuration:**
```env
hub_assistant_file_ids={"bengaluru": "assistant-CM47Ev6uB3u5G4T3wCtMYW", "mumbai": "assistant-XXXXXXXXXXXXXXXXXXXX"}
```

The application will continue to work with both configurations during the transition period.

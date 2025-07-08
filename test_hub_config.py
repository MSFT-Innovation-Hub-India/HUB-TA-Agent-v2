#!/usr/bin/env python3
"""
Test script to demonstrate the hub-specific assistant file ID functionality.
"""

from config import DefaultConfig
import json

def test_hub_file_ids():
    """Test the hub-specific file ID functionality."""
    print("Testing Hub-Specific Assistant File ID Configuration")
    print("=" * 60)
    
    # Initialize config
    config = DefaultConfig()
    
    # Test cases with different hub name formats
    test_cases = [
        "Bengaluru",
        "BENGALURU", 
        "bengaluru",
        "New Delhi",
        "new delhi",
        "NEW DELHI",
        "Mumbai",
        "mumbai",
        "Chennai",
        "Hyderabad",
        "Invalid City",
        "",
        None
    ]
    
    print("\nTesting normalize_hub_name method:")
    print("-" * 40)
    for test_case in test_cases:
        normalized = config.normalize_hub_name(test_case)
        print(f"'{test_case}' -> '{normalized}'")
    
    print("\nTesting get_hub_assistant_file_id method:")
    print("-" * 40)
    for test_case in test_cases:
        file_id = config.get_hub_assistant_file_id(test_case)
        print(f"'{test_case}' -> '{file_id}'")
    
    print("\nAll configured hub file IDs:")
    print("-" * 40)
    all_file_ids = config.get_all_hub_file_ids()
    for hub, file_id in all_file_ids.items():
        print(f"Hub: {hub} -> File ID: {file_id}")
    
    print("\nExample .env configuration:")
    print("-" * 40)
    example_config = {
        "bengaluru": "assistant-CM47Ev6uB3u5G4T3wCtMYW",
        "mumbai": "assistant-XXXXXXXXXXXXXXXXXXXX",
        "delhi": "assistant-YYYYYYYYYYYYYYYYYYYY",
        "newdelhi": "assistant-YYYYYYYYYYYYYYYYYYYY",  # Alternative key for "New Delhi"
        "chennai": "assistant-ZZZZZZZZZZZZZZZZZZZZ",
        "hyderabad": "assistant-AAAAAAAAAAAAAAAAAAAAA"
    }
    print(f"hub_assistant_file_ids={json.dumps(example_config)}")

if __name__ == "__main__":
    test_hub_file_ids()

"""Compatibility wrapper so existing launch scripts can continue to call app.py."""

from agent_sdk import main


if __name__ == "__main__":
    main()

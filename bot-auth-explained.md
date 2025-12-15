# Azure Bot Service + Container App Authentication Flow

## Architecture Overview

```
Teams/Channels → Azure Bot Service → Container App (/api/messages)
                      ↓                      ↓
              Uses App ID only        Uses App ID + Secret
              (MS infra signs tokens) (for outbound replies)
```

## Component Responsibilities

| Component | What it uses | Purpose |
|-----------|--------------|---------|
| **Azure Bot Service** | App ID only | Routes messages, Microsoft's infrastructure signs the JWT tokens sent to your bot |
| **Container App** | App ID + Secret | Validates inbound tokens (App ID), authenticates outbound calls (App ID + Secret) |

## Message Flow

### Inbound (User → Bot Service → Container App)

```
Teams User → Azure Bot Service → Your Container App
                   |                     |
            Signs JWT with          Validates JWT using
            Microsoft's keys         App ID only
```

1. **Bot Service receives message from Teams**
2. **Bot Service creates a JWT token** - This token is signed by **Microsoft's infrastructure**, not your App Registration secret
3. **Bot Service forwards to your Container App** with this Bearer token
4. **Your Container App validates the token** - It checks:
   - Token was issued by Microsoft's identity platform
   - Token's `audience` matches your App ID
   - Token hasn't expired

**No secret needed for inbound validation** - your bot just verifies the token signature against Microsoft's public keys.

### Outbound (Container App → Bot Service → User)

```
Your Container App → Bot Connector API → Azure Bot Service → Teams User
         |
   Uses App ID + Secret
   to get access token
```

1. **Your bot code wants to send a reply**
2. **Bot SDK authenticates to Azure AD** using App ID + Client Secret
3. **Gets an access token** for the Bot Connector service
4. **Sends the message** with that token

**This is why your Container App needs the secret** - it's the one making authenticated outbound calls.

## What the Bot Service Actually Stores

When you create a Bot Service and link an App Registration:

| Bot Service Knows | Bot Service Does NOT Store |
|-------------------|---------------------------|
| App ID | Client Secret |
| Messaging Endpoint URL | |
| Which channels are enabled | |

The Bot Service only stores a **reference** to the App Registration (the App ID). It uses Microsoft's internal infrastructure to:
- Route messages to your endpoint
- Sign tokens that your bot can validate

## JWT Token Details

### Token Signing vs Token Contents

| Aspect | What's Used | Details |
|--------|-------------|---------|
| **Signing the JWT** | Microsoft's private keys | Bot Framework infrastructure signs tokens with keys only Microsoft controls |
| **Inside the JWT (claims)** | Your App ID | Included as the `audience` (aud) claim |

### Example JWT Structure

```json
{
  "iss": "https://api.botframework.com",
  "aud": "<Your-App-ID>",
  "exp": "...",
  ...
}
// Signed with: Microsoft's private key (not your secret)
```

### How Your Container App Validates Inbound Tokens

1. **Fetches Microsoft's public keys** from the Bot Framework's OpenID metadata endpoint
2. **Verifies the signature** using those public keys
3. **Checks the `aud` claim** matches your App ID
4. **Checks expiration** and other standard JWT claims

## Summary Table

| Component | Has App ID | Has Secret | Why |
|-----------|------------|------------|-----|
| **Bot Service** | ✅ Yes | ❌ No | Only needs to route messages and sign tokens (done by MS infrastructure) |
| **Container App** | ✅ Yes | ✅ Yes | Needs to validate inbound tokens AND authenticate for outbound messages |
| **App Registration** | ✅ Yes | ✅ Yes (stored in Azure AD) | Source of truth for the identity |

## Key Takeaways

- **Microsoft signs** the token (with their private keys)
- **Your App ID is inside** the token (as the intended audience)
- **Your bot validates** that the token is from Microsoft AND addressed to your App ID
- **Your bot uses the secret** only when sending messages back through the Bot Connector API

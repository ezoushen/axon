# Environment Files in AXON

AXON automatically loads environment files for deployment configuration.

## Quick Start

### 1. Create Environment File
```bash
cp .env.axon.example .env.axon
vim .env.axon
```

### 2. Add Credentials
```bash
DOCKER_HUB_USERNAME=myuser
DOCKER_HUB_TOKEN=dckr_pat_xxxxx
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_REGION=us-east-1
AWS_ACCOUNT_ID=123456789012
```

### 3. Run AXON
```bash
axon run production
# Output: [INFO] Loaded environment from: .env.axon
```

## File Discovery Order

AXON searches for and loads the **first file found**:

1. `.env.axon` (recommended)
2. `.env.local` (alternative)
3. `.env` (fallback)

## What Goes Where?

### `.env.axon` (Deployment-Time)
**Purpose**: AXON deployment configuration  
**Location**: Local machine (project root)  
**Contains**: Registry credentials, server config, build-time variables

```bash
# Registry credentials
DOCKER_HUB_USERNAME=myuser
DOCKER_HUB_TOKEN=dckr_pat_xxxxx

# AWS configuration
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=xxx
AWS_REGION=us-east-1
AWS_ACCOUNT_ID=123456789012

# Build-time public variables
NEXT_PUBLIC_API_URL=https://api.example.com
```

### `.env.production` (Runtime)
**Purpose**: Application runtime configuration  
**Location**: Application Server (remote)  
**Managed via**: `axon env edit production`  
**Contains**: Database URLs, API secrets, app config

```bash
# Application secrets (runtime)
DATABASE_URL=postgresql://...
REDIS_URL=redis://...
API_SECRET_KEY=xxxxx
STRIPE_SECRET_KEY=sk_live_xxxxx
NODE_ENV=production
```

## Security

### Automatically Gitignored
```gitignore
.env
.env.local
.env.axon
.env*.local
```

### Safe to Commit
```gitignore
.env.axon.example  # Template file
```

## File Format

```bash
# Comments start with #
KEY=value                    # Simple
KEY="quoted value"           # Quotes removed
KEY='single quoted'          # Quotes removed

# Blank lines and comments are skipped
```

## CI/CD Integration

No `.env` file needed in CI/CD - use platform secrets:

```yaml
# GitHub Actions
jobs:
  deploy:
    env:
      DOCKER_HUB_USERNAME: ${{ secrets.DOCKER_HUB_USERNAME }}
      DOCKER_HUB_TOKEN: ${{ secrets.DOCKER_HUB_TOKEN }}
    run: axon run production
```

## Troubleshooting

### File Not Loading?
- File must be in project root (same directory as `axon.config.yml`)
- Check filename: `.env.axon`, `.env.local`, or `.env`

### Variables Not Expanding?
Use correct syntax in `axon.config.yml`:
```yaml
# Correct
username: "${DOCKER_HUB_USERNAME}"

# Wrong
username: "$DOCKER_HUB_USERNAME"
```

### Multiple Files?
Only the **first file found** is loaded. Priority: `.env.axon` > `.env.local` > `.env`

## See Also

- `.env.axon.example` - Complete template
- `CHANGES_SUMMARY.md` - v0.7.0 improvements
- `README.md` - Main documentation

## Config File vs Environment Files

### Important: Config Files Are Safe to Commit

As of v0.8.0, **`axon.config.yml` should be committed to git** because it uses environment variable syntax (`${VAR_NAME}`):

```yaml
# axon.config.yml - SAFE TO COMMIT
registry:
  docker_hub:
    username: "${DOCKER_HUB_USERNAME}"    # Variable, not actual value
    access_token: "${DOCKER_HUB_TOKEN}"  # Variable, not actual value
```

### What NOT to Commit

Only the environment files containing actual credentials should be gitignored:

```bash
# .gitignore
.env
.env.local
.env.axon
.env*.local
```

### Summary

| File | Contains | Commit? | Example |
|------|----------|---------|---------|
| `axon.config.yml` | Variable references | ✅ YES | `username: "${DOCKER_HUB_USERNAME}"` |
| `.env.axon` | Actual credentials | ❌ NO | `DOCKER_HUB_USERNAME=myuser` |
| `.env.axon.example` | Templates | ✅ YES | `DOCKER_HUB_USERNAME=your-username` |

### Migration from Old Versions

If you used AXON before v0.8.0, your config file might be in `.gitignore`. Remove it:

```bash
# Check if config is gitignored
git check-ignore axon.config.yml

# If it returns the filename, remove it from .gitignore
vim .gitignore  # Remove the axon.config.yml line

# Now you can commit it safely
git add axon.config.yml
git commit -m "Add AXON config (safe with env var syntax)"
```

### Why This Changed

**Before v0.8.0:**
- Config files contained actual credentials (unsafe to commit)
- `axon config init` added config to `.gitignore`

**After v0.8.0:**
- Config files use `${VAR}` syntax (safe to commit)
- Credentials go in `.env.axon` (gitignored)
- `axon config init` NO LONGER adds config to `.gitignore`

# Network Aliases for Container Communication

Each container gets a **stable DNS name** within its network, solving the dynamic container naming problem.

## The Problem

- Container names include timestamps: `linebot-nextjs-production-1760809226`
- Names change on every deployment
- Hard to reference from other containers

## The Solution

Configure a network alias in `deploy.config.yml`:

```yaml
docker:
  network_alias: "app"  # Stable DNS name
```

## How to Use

Containers on the same network can communicate using the alias:

```bash
# From another container on the same network:
curl http://app:3000/api/health

# Works even though actual container name is:
# linebot-nextjs-production-1760809226
```

## Benefits

- ✅ No need to know the dynamic container name
- ✅ Works across deployments (name stays the same)
- ✅ Network-isolated (production and staging have separate networks)
- ✅ Perfect for multi-container setups (app + database, app + redis, etc.)

## Example Multi-Container Setup

```yaml
# deploy.config.yml
docker:
  network_alias: "web"  # Your app is accessible as "web"

# Another container on the same network can:
# - Connect to database: postgres:5432
# - Connect to your app: web:3000
# - Connect to redis: redis:6379
```

**Note:** This only works for container-to-container communication on the same Docker network. External access still uses the exposed port managed by nginx.

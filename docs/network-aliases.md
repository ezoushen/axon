# Network Aliases for Container Communication

Each container gets a **stable DNS name** within its network, solving the dynamic container naming problem.

## The Problem

- Container names include timestamps: `my-product-production-1760809226`
- Names change on every deployment
- Hard to reference from other containers

## The Solution

Configure a network alias in `axon.config.yml`:

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
# my-product-production-1760809226
```

## Benefits

- ✅ No need to know the dynamic container name
- ✅ Works across deployments (name stays the same)
- ✅ Network-isolated (production and staging have separate networks)
- ✅ Perfect for multi-container setups (app + database, app + redis, etc.)
- ✅ Zero-downtime deployments for internal traffic (old containers disconnected before shutdown)

## Example Multi-Container Setup

```yaml
# axon.config.yml
docker:
  network_alias: "web"  # Your app is accessible as "web"

# Another container on the same network can:
# - Connect to database: postgres:5432
# - Connect to your app: web:3000
# - Connect to redis: redis:6379
```

## Zero-Downtime Deployment with Network Aliases

AXON ensures zero-downtime for both external and internal traffic when using network aliases:

**Deployment Flow:**
1. New container starts with network alias (e.g., `app`)
2. Health check passes
3. nginx switches external traffic to new container
4. **Old containers disconnected from network** → DNS alias removed immediately
5. All internal traffic (via alias) now goes to new container only
6. Old containers gracefully shutdown with existing requests draining

This prevents the race condition where both old and new containers share the same DNS alias, ensuring predictable routing for internal services.

**Note:** Network aliases only work for container-to-container communication on the same Docker network. External access uses the exposed port managed by nginx.

# Graceful Shutdown

When deploying a new container, the old container is shut down gracefully to ensure:
- Current requests finish processing
- Database connections are closed properly
- Resources are cleaned up
- Logs are flushed

## How it Works

1. After nginx switches to the new container, the deployment script sends **SIGTERM** to the old container
2. The application receives the signal and can handle it (e.g., stop accepting new requests, finish current work)
3. Docker waits up to `graceful_shutdown_timeout` seconds (default: 30s)
4. If the container is still running after timeout, Docker sends **SIGKILL** (force kill)

## Configuration

Configure the graceful shutdown timeout in `axon.config.yml`:

```yaml
# axon.config.yml
deployment:
  graceful_shutdown_timeout: 30  # Seconds to wait before force kill
```

## Application Support

For your application to handle graceful shutdown properly, you need to listen for the SIGTERM signal.

### Node.js Example

```javascript
// Handle graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, starting graceful shutdown...');

  server.close(() => {
    console.log('HTTP server closed');

    // Close database connections, etc.
    process.exit(0);
  });

  // Force exit if graceful shutdown takes too long
  setTimeout(() => {
    console.error('Forced shutdown due to timeout');
    process.exit(1);
  }, 28000); // Slightly less than Docker's timeout
});
```

### Python Example

```python
import signal
import sys

def graceful_shutdown(signum, frame):
    print('SIGTERM received, starting graceful shutdown...')

    # Close database connections
    # Finish current requests
    # Cleanup resources

    sys.exit(0)

signal.signal(signal.SIGTERM, graceful_shutdown)
```

## Benefits

- ✅ No abrupt connection terminations
- ✅ Prevents data loss or corruption
- ✅ Clean resource cleanup
- ✅ Configurable timeout for different application needs

## Best Practices

1. **Set appropriate timeout**: Match your application's typical request duration
2. **Implement signal handlers**: Always handle SIGTERM in your application code
3. **Test shutdown behavior**: Verify connections close cleanly
4. **Monitor shutdown time**: Ensure it completes within the configured timeout

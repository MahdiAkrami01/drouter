# drouter

Dynamic route injection for Docker containers via labels. A systemd service that monitors Docker containers and automatically configures static routes in their network namespaces without requiring elevated privileges.

## Requirements

- Docker 17.06+
- systemd 219+
- bash 4.0+
- jq 1.5+
- iproute2
- util-linux (for nsenter)

### Install Dependencies

**Ubuntu/Debian:**

```bash
sudo apt-get update && sudo apt-get install -y jq util-linux iproute2
```

**RHEL/CentOS/Fedora:**

```bash
sudo yum install -y jq util-linux iproute
```

## Installation

```bash
# Download files
wget https://raw.githubusercontent.com/lanrat/drouter/main/drouter.sh
wget https://raw.githubusercontent.com/lanrat/drouter/main/drouter.service

# Install script
sudo cp drouter.sh /usr/local/bin/drouter
sudo chmod +x /usr/local/bin/drouter

# Install systemd service
sudo cp drouter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable drouter
sudo systemctl start drouter
```

## Usage

Add labels to your Docker containers to configure static routes:

```yaml
version: '3.8'
services:
  app:
    image: nginx
    labels:
      drouter.routes.ipv4: "10.0.0.0/8 via 172.17.0.1;192.168.0.0/16 via 172.17.0.2"
      drouter.routes.ipv6: "2001:db8::/32 via fe80::1"
      drouter.routes.delay: "2"  # Optional: wait 2 seconds before adding routes
```

Or with `docker run`:

```bash
docker run -d \
  --label drouter.routes.ipv4="10.0.0.0/8 via 172.17.0.1" \
  --label drouter.routes.ipv6="2001:db8::/32 via fe80::1" \
  --label drouter.routes.delay="2" \
  nginx
```

### Label Reference

| Label | Description |
|-------|-------------|
| `drouter.routes.ipv4` | Semicolon-separated IPv4 routes |
| `drouter.routes.ipv6` | Semicolon-separated IPv6 routes |
| `drouter.routes.delay` | Seconds to wait before adding routes (default: 0) |

### Route Format

Routes use standard iproute2 syntax:
- IPv4: `<destination> via <gateway>`
- IPv6: `<destination> via <gateway>`
- Multiple routes: separate with semicolons

## Configuration

Edit `/etc/systemd/system/drouter.service` to adjust:

```ini
Environment="LOG_LEVEL=INFO"         # DEBUG, INFO, WARN, ERROR
Environment="DEFAULT_ROUTE_DELAY=0"  # Default delay in seconds
Environment="RETRY_ATTEMPTS=3"       # Retry attempts for failed routes
```

Apply changes:

```bash
sudo systemctl daemon-reload
sudo systemctl restart drouter
```

## Monitoring

View service status:

```bash
sudo systemctl status drouter
```

View logs:

```bash
# Recent logs
sudo journalctl -u drouter -n 50

# Follow logs
sudo journalctl -u drouter -f

# Debug issues
sudo LOG_LEVEL=DEBUG systemctl restart drouter
sudo journalctl -u drouter -f
```

## Verify Routes

Check if routes were added successfully:

```bash
# List routes in a container
docker exec <container> ip route
docker exec <container> ip -6 route

# Check service processed the container
sudo journalctl -u drouter | grep <container>
```

## Troubleshooting

### Routes Not Added

1. Check container has the correct labels:
   ```bash
   docker inspect <container> | jq '.[] | .Config.Labels'
   ```

2. Verify service is running:
   ```bash
   sudo systemctl status drouter
   ```

3. Check for errors in logs:
   ```bash
   sudo journalctl -u drouter -n 100 | grep ERROR
   ```

### Common Issues

- **Container using host networking**: Routes are not needed (uses host routing table)
- **Container not running**: Routes are only added to running containers
- **Invalid route syntax**: Check route format matches iproute2 syntax
- **Gateway unreachable**: Ensure gateway IP is accessible from container's network

## How It Works

1. drouter monitors Docker events for container starts, restarts, and unpauses
2. When a container with `drouter.routes.*` labels is detected, it reads the configuration
3. After an optional delay, it enters the container's network namespace using `nsenter`
4. Routes are added using `ip route add` commands
5. Existing routes are preserved and duplicates are avoided
6. On service startup, all running containers are processed for any missing routes

## Notes

- Routes are automatically re-added when containers restart
- The service handles Docker daemon restarts gracefully
- Containers don't need NET_ADMIN capability or root privileges
- Routes are not added to containers using host, none, or shared network modes
- Labels cannot be modified on running containers (requires container recreation)

## License

MIT
#!/bin/bash
# drouter - Dynamic route injection for Docker containers
# https://github.com/lanrat/drouter

# Enable safe scripting options selectively
# Not using set -e because we handle errors explicitly
# Not using set -u because we use intentional empty defaults
# Using set -o pipefail only for critical pipelines
set -o noclobber  # Prevent accidental file overwrites

# Configuration
LABEL_KEY_V4="${DROUTER_LABEL_V4:-drouter.routes.ipv4}"
LABEL_KEY_V6="${DROUTER_LABEL_V6:-drouter.routes.ipv6}"
LABEL_KEY_DELAY="${DROUTER_LABEL_DELAY:-drouter.routes.delay}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-1}"
DEFAULT_ROUTE_DELAY="${DEFAULT_ROUTE_DELAY:-0}"  # Default delay before adding routes

# Logging functions
log() {
    local level=$1
    shift
    echo "$(date -Iseconds) [$level] $*" | systemd-cat -t drouter -p "${level,,}"
}

log_debug() { [[ "$LOG_LEVEL" == "DEBUG" ]] && log DEBUG "$@"; }
log_info() { log INFO "$@"; }
log_warn() { log WARNING "$@"; }
log_error() { log ERROR "$@"; }

# Check if route already exists
route_exists() {
    local pid=$1
    local route=$2
    local ip_ver=$3
    
    # Parse route components
    local dest="${route%% via*}"
    local gateway="${route##* via }"
    
    # Check both destination and gateway
    local existing_route
    # shellcheck disable=SC2086  # ip_ver intentionally unquoted (empty for v4, -6 for v6)
    if ! existing_route=$(nsenter -t "$pid" -n ip ${ip_ver} route show "$dest" 2>/dev/null); then
        # Route doesn't exist, this is expected
        return 1
    fi
    
    if [ -n "$existing_route" ]; then
        if [[ "$existing_route" == *"via $gateway"* ]]; then
            return 0  # Exact route exists
        else
            # Different gateway - remove old route first
            log_info "Replacing route $dest with new gateway $gateway"
            # shellcheck disable=SC2086  # ip_ver intentionally unquoted
            nsenter -t "$pid" -n ip ${ip_ver} route del "$dest" 2>/dev/null
            return 1
        fi
    fi
    
    return 1  # Route doesn't exist
}

# Add a single route with error handling
add_single_route() {
    local pid=$1
    local route=$2
    local container=$3
    local ip_ver=${4:-}  # -6 for IPv6, empty for IPv4
    
    local dest="${route%% via*}"
    
    # Check if route already exists
    if route_exists "$pid" "$route" "$ip_ver"; then
        log_debug "Route $route already exists for container $container"
        return 0
    fi
    
    # Try to add the route with retries
    local attempt=1
    while [ "$attempt" -le "$RETRY_ATTEMPTS" ]; do
        local error
        # shellcheck disable=SC2086  # Both intentionally unquoted: ip_ver can be empty, route contains multiple args
        if error=$(nsenter -t "$pid" -n ip ${ip_ver} route add ${route} 2>&1); then
            log_info "Successfully added route '$route' to container $container"
            return 0
        else
            log_warn "Attempt $attempt/$RETRY_ATTEMPTS failed for route '$route' on $container: $error"
        fi
        
        sleep "$RETRY_DELAY"
        ((attempt++))
    done
    
    log_error "Failed to add route '$route' to container $container after $RETRY_ATTEMPTS attempts"
    return 1
}

# Process routes for a container
process_container_routes() {
    local container=$1
    local action=$2
    
    # Get container details
    local inspect_json
    if ! inspect_json=$(docker inspect "$container" 2>/dev/null); then
        log_error "Failed to inspect container $container"
        return 1
    fi
    
    # Check if container is running
    local state
    state=$(echo "$inspect_json" | jq -r '.[0].State.Status')
    if [ "$state" != "running" ]; then
        log_debug "Container $container is not running (state: $state), skipping"
        return 0
    fi
    
    # Get PID
    local pid
    pid=$(echo "$inspect_json" | jq -r '.[0].State.Pid')
    if [ "$pid" == "0" ] || [ "$pid" == "null" ]; then
        log_warn "Container $container has no valid PID, might be restarting"
        return 1
    fi
    
    # Check network mode
    local network_mode
    network_mode=$(echo "$inspect_json" | jq -r '.[0].HostConfig.NetworkMode')
    
    # Skip certain network modes
    case "$network_mode" in
        "host")
            log_debug "Container $container uses host networking, skipping routes"
            return 0
            ;;
        "none")
            log_debug "Container $container has no networking, skipping routes"
            return 0
            ;;
        container:*)
            log_debug "Container $container shares another container's network, skipping"
            return 0
            ;;
    esac
    
    # Get configured delay for this container
    local route_delay
    route_delay=$(echo "$inspect_json" | jq -r ".[0].Config.Labels[\"$LABEL_KEY_DELAY\"] // \"$DEFAULT_ROUTE_DELAY\"")
    
    # Validate delay is a number
    if ! [[ "$route_delay" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "Invalid delay value '$route_delay' for container $container, using default"
        route_delay=$DEFAULT_ROUTE_DELAY
    fi
    
    # Apply delay if specified
    if [ "$route_delay" != "0" ]; then
        log_info "Waiting ${route_delay}s before adding routes to container $container"
        sleep "$route_delay"
        
        # Re-check if container is still running after delay
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
        if [ "$state" != "running" ]; then
            log_debug "Container $container is no longer running after delay, skipping"
            return 0
        fi
        
        # Re-get PID in case it changed
        pid=$(docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null)
        if [ -z "$pid" ] || [ "$pid" == "0" ]; then
            log_warn "Container $container has no valid PID after delay"
            return 1
        fi
    fi
    
    # Get IPv4 routes
    local routes_v4
    routes_v4=$(echo "$inspect_json" | jq -r ".[0].Config.Labels[\"$LABEL_KEY_V4\"] // \"\"")
    
    # Get IPv6 routes
    local routes_v6
    routes_v6=$(echo "$inspect_json" | jq -r ".[0].Config.Labels[\"$LABEL_KEY_V6\"] // \"\"")
    
    if [ -z "$routes_v4" ] && [ -z "$routes_v6" ]; then
        log_debug "Container $container has no static routes defined"
        return 0
    fi
    
    log_info "Processing routes for container $container (network: $network_mode, pid: $pid)"
    
    # Process IPv4 routes
    if [ -n "$routes_v4" ]; then
        # Support both semicolon and newline separators
        # Replace newlines with semicolons for consistent processing
        routes_v4=$(echo "$routes_v4" | tr '\n' ';')
        
        IFS=';' read -ra ROUTE_ARRAY <<< "$routes_v4"
        for route in "${ROUTE_ARRAY[@]}"; do
            # Trim whitespace
            route=$(echo "$route" | xargs)
            if [ -n "$route" ]; then
                add_single_route "$pid" "$route" "$container" ""
            fi
        done
    fi
    
    # Process IPv6 routes
    if [ -n "$routes_v6" ]; then
        # Support both semicolon and newline separators
        # Replace newlines with semicolons for consistent processing
        routes_v6=$(echo "$routes_v6" | tr '\n' ';')
        
        IFS=';' read -ra ROUTE_ARRAY <<< "$routes_v6"
        for route in "${ROUTE_ARRAY[@]}"; do
            # Trim whitespace
            route=$(echo "$route" | xargs)
            if [ -n "$route" ]; then
                add_single_route "$pid" "$route" "$container" "-6"
            fi
        done
    fi
}

# Process existing containers on startup
process_existing_containers() {
    log_info "Processing existing containers with static routes..."
    
    local containers
    # Look for containers with any of our labels
    containers=$(docker ps --filter "label=$LABEL_KEY_V4" --format '{{.Names}}' 2>/dev/null)
    containers+=$'\n'$(docker ps --filter "label=$LABEL_KEY_V6" --format '{{.Names}}' 2>/dev/null)
    
    # Remove duplicates and empty lines
    containers=$(echo "$containers" | sort -u | grep -v '^$' || true)
    
    if [ -n "$containers" ]; then
        while IFS= read -r container; do
            [ -z "$container" ] && continue
            process_container_routes "$container" "startup"
        done <<< "$containers"
    fi
    
    log_info "Finished processing existing containers"
}

# Main monitoring loop
main() {
    log_info "drouter starting (labels: $LABEL_KEY_V4, $LABEL_KEY_V6, $LABEL_KEY_DELAY, log level: $LOG_LEVEL)"
    
    # Process existing containers
    process_existing_containers
    
    # Monitor events
    log_info "Monitoring Docker events..."

    # Monitor start events for containers with drouter labels
    # Note: Labels cannot be changed on running containers, so no need to monitor update events
    # Using separate processes for each label to implement OR logic between labels
    {
        docker events \
            --filter "label=$LABEL_KEY_V4" \
            --filter "event=start" \
            --format '{{json .}}' &

        docker events \
            --filter "label=$LABEL_KEY_V6" \
            --filter "event=start" \
            --format '{{json .}}' &

        wait
    } | while read -r event; do

        if [ -z "$event" ]; then
            continue
        fi

        local action container
        action=$(echo "$event" | jq -r '.Action')
        container=$(echo "$event" | jq -r '.Actor.Attributes.name // .Actor.ID[0:12]')

        log_debug "Received event: $action for container: $container"

        # Process container routes (delay is handled inside the function)
        # Note: route_exists() prevents duplicate routes if container has both labels
        process_container_routes "$container" "$action"
    done
}

# Trap signals for clean shutdown
trap 'log_info "Shutting down drouter"; exit 0' SIGTERM SIGINT

# Run main loop
main
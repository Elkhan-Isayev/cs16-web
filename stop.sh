#!/bin/bash
# Stop the CS 1.6 web server
cd "$(dirname "$0")"
docker compose down
echo "Server stopped."

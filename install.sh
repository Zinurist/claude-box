#!/bin/bash
podman build -t claude-box .
cp claude-box ~/.local/bin/claude-box
chmod +x ~/.local/bin/claude-box

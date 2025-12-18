#! /bin/bash

sudo -u showroom -H bash -c '
set -e

cd /opt/showroom/content
cp www/index.html /tmp/index.html
git pull

podman run --rm \
  --pull=always \
  -v "$(pwd):/antora:Z" \
  docker.io/antora/antora:latest \
  default-site.yml

cp /tmp/index.html www/index.html
'
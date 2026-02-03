#! /bin/bash

sudo -u showroom -H bash -c '
set -e

cd /opt/showroom/content

cp content/antora.yml /tmp/antora.yml
cp www/index.html /tmp/index.html
git stash
git pull

podman run --rm \
  --pull=always \
  -v "$(pwd):/antora:Z" \
  docker.io/antora/antora:latest \
  default-site.yml

cp /tmp/index.html www/index.html
cp /tmp/antora.yml content/antora.yml
'
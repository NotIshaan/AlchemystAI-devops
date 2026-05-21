#!/bin/bash
set -e

sudo dnf install -y git curl nginx python3-pip
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo dnf install -y nodejs
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

git clone https://github.com/NotIshaan/AlchemystAI-devops.git ~/app

cd ~/app/workers/caller-worker
npm install

cd ~/app/workers/inference-worker
pip3 install -r requirements.txt

sudo tee /etc/nginx/conf.d/alchemyst.conf > /dev/null <<'NGINX'
server {
    listen 3111;
    location / {
        proxy_pass http://10.0.2.16:3111;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX

sudo systemctl enable nginx
sudo systemctl start nginx
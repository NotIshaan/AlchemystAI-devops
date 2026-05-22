#!/bin/bash
set -e

# ==========================================
# 1. VALIDATE INPUTS
# ==========================================
if [ "$#" -ne 2 ]; then
    echo "Usage: ./setup.sh <CALLER_VM_IP> <INFERENCE_VM_IP>"
    exit 1
fi

CALLER_IP=$1
INFERENCE_IP=$2
SSH_KEY="~/.ssh/alchemyst"

echo "Starting automated air-gapped deployment..."
echo "Targeting Caller at $CALLER_IP and Inference at $INFERENCE_IP."

# ==========================================
# Phase 1: Deep Clean (Idempotency Guarantee)
# ==========================================
echo "Phase 1: Aggressively cleaning up old artifacts and caches..."
rm -rf ~/app ~/python311-rpms ~/py-wheels ~/.cache/huggingface ~/.cache/pip ~/.local/lib/python311 ~/tmp ~/.npm
rm -f ~/node-v20.tar.xz ~/caller-dist.tar.gz ~/python311-offline.tar.gz ~/py-wheels.tar.gz ~/py-libs.tar.gz ~/hf-cache.tar.gz ~/inference_worker.py
sudo dnf clean all

# ==========================================
# Phase 2: Gateway Tooling
# ==========================================
echo "Phase 2: Installing Gateway build tools and packages..."
sudo dnf install -y python3.11 python3.11-pip git nginx nodejs
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh

echo "Configuring the Nginx reverse proxy..."
sudo bash -c "cat > /etc/nginx/conf.d/api.conf <<EOF
server {
    listen 80;
    location / {
        proxy_pass http://$CALLER_IP:3111;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
    }
}
EOF"
sudo systemctl enable --now nginx
sudo systemctl restart nginx

# ==========================================
# Phase 3: Sequential Artifact Processing
# ==========================================

# --- Component 1: Node.js & Caller Worker ---
echo "Phase 3a: Processing Node.js & Caller Worker..."
mkdir -p ~/tmp
git clone https://github.com/NotIshaan/AlchemystAI-devops.git ~/app
cp ~/app/workers/inference-worker/inference_worker.py ~/inference_worker.py

curl -s -o ~/node-v20.tar.xz https://nodejs.org/dist/v20.14.0/node-v20.14.0-linux-x64.tar.xz

cd ~/app/workers/caller-worker
TMPDIR=~/tmp TEMP=~/tmp TMP=~/tmp npm install
npm run build
cd ~

tar -czf ~/caller-dist.tar.gz -C ~/app workers/caller-worker/
rm -rf ~/app
rm -rf ~/.npm ~/tmp

echo "Shipping Node.js and Caller payloads..."
ssh -i $SSH_KEY -o StrictHostKeyChecking=no ec2-user@$CALLER_IP "mkdir -p ~/app /home/ec2-user/.local/bin"
scp -i $SSH_KEY ~/.local/bin/iii ~/node-v20.tar.xz ~/caller-dist.tar.gz ec2-user@$CALLER_IP:~
rm -f ~/node-v20.tar.xz ~/caller-dist.tar.gz

# --- Component 2: Python 3.11 RPMs ---
echo "Phase 3b: Processing Python 3.11 RPMs..."
mkdir -p ~/python311-rpms && cd ~/python311-rpms
sudo dnf download --resolve -y python3.11 python3.11-libs mpdecimal python3.11-pip-wheel python3.11-setuptools-wheel
cd ~

tar -czf ~/python311-offline.tar.gz python311-rpms/
rm -rf ~/python311-rpms

echo "Shipping Python 3.11 RPMs..."
ssh -i $SSH_KEY -o StrictHostKeyChecking=no ec2-user@$INFERENCE_IP "mkdir -p ~/app/workers/inference-worker /home/ec2-user/.local/bin /home/ec2-user/.local/lib"
scp -i $SSH_KEY ~/python311-offline.tar.gz ec2-user@$INFERENCE_IP:~
rm -f ~/python311-offline.tar.gz

# --- Component 3: Python Wheels ---
echo "Phase 3c: Processing Python Wheels..."
mkdir -p ~/py-wheels ~/tmp
TMPDIR=~/tmp TEMP=~/tmp TMP=~/tmp pip3.11 download --no-cache-dir iii-sdk==0.12.0 watchfiles transformers gguf accelerate torch huggingface_hub --extra-index-url https://download.pytorch.org/whl/cpu -d ~/py-wheels

tar -czf ~/py-wheels.tar.gz py-wheels/
rm -rf ~/py-wheels ~/tmp

echo "Shipping Python Wheels..."
scp -i $SSH_KEY ~/py-wheels.tar.gz ec2-user@$INFERENCE_IP:~
rm -f ~/py-wheels.tar.gz

# --- Component 4: Gemma 3 270M GGUF Model ---
echo "Phase 3d: Downloading Gemma Model using HF CLI..."
mkdir -p ~/tmp
TMPDIR=~/tmp TEMP=~/tmp TMP=~/tmp pip3.11 install --user --no-cache-dir huggingface_hub
export PATH=$PATH:~/.local/bin
TMPDIR=~/tmp TEMP=~/tmp TMP=~/tmp hf download ggml-org/gemma-3-270m-GGUF gemma-3-270m-Q8_0.gguf

echo "Packaging and shipping Gemma Model cache..."
tar -czf ~/hf-cache.tar.gz -C ~ .cache/huggingface/
rm -rf ~/.cache/huggingface ~/tmp

scp -i $SSH_KEY ~/hf-cache.tar.gz ~/inference_worker.py ec2-user@$INFERENCE_IP:~
rm -f ~/hf-cache.tar.gz ~/inference_worker.py

# ==========================================
# Phase 4: Remote Execution
# ==========================================

echo "Phase 4a: Setting up services on Caller VM..."
ssh -i $SSH_KEY ec2-user@$CALLER_IP "bash -s" << 'EOF'
    # Install Node
    sudo tar -xf ~/node-v20.tar.xz -C /usr/local --strip-components=1
    
    # Install iii engine
    mv ~/iii ~/.local/bin/iii && chmod +x ~/.local/bin/iii
    
    # Extract app
    tar -xzf ~/caller-dist.tar.gz -C ~/app
    find ~/app -name "iii.worker.yaml" -exec mv {} {}.disabled \;

    # Write Engine Config
    cat << 'CFG' > ~/app/engine.yaml
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 60000
CFG

    # Setup Systemd for iii-engine
    cat << 'SYS' > ~/iii-engine.service
[Unit]
Description=III Engine
[Service]
ExecStart=/home/ec2-user/.local/bin/iii --config /home/ec2-user/app/engine.yaml
Restart=always
User=ec2-user
[Install]
WantedBy=multi-user.target
SYS
    sudo mv ~/iii-engine.service /etc/systemd/system/iii-engine.service

    # Setup Systemd for Caller Worker
    cat << 'SYS' > ~/caller-worker.service
[Unit]
Description=Caller Worker
[Service]
WorkingDirectory=/home/ec2-user/app/workers/caller-worker
Environment=III_URL=ws://127.0.0.1:49134
ExecStart=/usr/local/bin/npm run dev
Restart=always
User=ec2-user
[Install]
WantedBy=multi-user.target
SYS
    sudo mv ~/caller-worker.service /etc/systemd/system/caller-worker.service

    sudo systemctl daemon-reload
    sudo systemctl enable --now iii-engine.service caller-worker.service
    
    # Clean up transferred archives
    rm -f ~/node-v20.tar.xz ~/caller-dist.tar.gz
EOF

echo "Phase 4b: Setting up services on Inference VM..."
ssh -i $SSH_KEY ec2-user@$INFERENCE_IP "CALLER_IP=$CALLER_IP bash -s" << 'EOF'
    # Setup Swap to prevent OOM (allocate 4GB)
    if [ ! -f /swapfile ]; then
        sudo dd if=/dev/zero of=/swapfile bs=1M count=4096
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi

    # Offline Python Install
    tar -xzf ~/python311-offline.tar.gz
    sudo dnf localinstall -y --disablerepo="*" python311-rpms/*.rpm
    
    # Bootstrap pip using ensurepip
    python3.11 -m ensurepip --upgrade --default-pip
    
    # Offline Python Libraries Install
    tar -xzf ~/py-wheels.tar.gz
    python3.11 -m pip install --no-index --find-links=py-wheels py-wheels/*
    
    # Extract App & Cache
    tar -xzf ~/hf-cache.tar.gz
    mv ~/inference_worker.py ~/app/workers/inference-worker/


    # Setup Systemd
    cat << SYS > ~/inference-worker.service
[Unit]
Description=Inference Worker
[Service]
WorkingDirectory=/home/ec2-user/app/workers/inference-worker
Environment=III_URL=ws://${CALLER_IP}:49134
Environment=HF_HUB_OFFLINE=1
Environment=OMP_NUM_THREADS=1
ExecStart=/usr/bin/python3.11 inference_worker.py
Restart=always
User=ec2-user
[Install]
WantedBy=multi-user.target
SYS
    sudo mv ~/inference-worker.service /etc/systemd/system/inference-worker.service

    sudo systemctl daemon-reload
    sudo systemctl enable --now inference-worker.service
    
    # Clean up transferred archives
    rm -f ~/py-wheels.tar.gz ~/python311-offline.tar.gz ~/hf-cache.tar.gz
EOF

echo "Deployment complete. The Nginx gateway is now listening on port 80."
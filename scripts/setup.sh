#!/bin/bash
set -e

# ==========================================
# 1. VALIDATE INPUTS
# ==========================================
if [ "$#" -ne 2 ]; then
    echo "Usage: ./deploy-all.sh <CALLER_VM_IP> <INFERENCE_VM_IP>"
    exit 1
fi

CALLER_IP=$1
INFERENCE_IP=$2
SSH_KEY="~/.ssh/alchemyst"

echo "Starting automated air-gapped deployment..."
echo "Targeting Caller at $CALLER_IP and Inference at $INFERENCE_IP."

# ==========================================
# 2. GATEWAY PREPARATION & PACKAGING
# ==========================================
echo "Installing build tools on the Gateway..."
sudo dnf install -y python3.11 python3.11-pip git nginx
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

echo "Fetching and bundling Node.js and npm dependencies for the Caller worker..."
git clone https://github.com/NotIshaan/AlchemystAI-devops.git ~/app
curl -s -o node-v20.tar.xz https://nodejs.org/dist/v20.14.0/node-v20.14.0-linux-x64.tar.xz
cd ~/app/workers/caller-worker && npm install && npm run build && cd ~/app
tar -czf caller-dist.tar.gz workers/caller-worker/

echo "Downloading raw Python 3.11 RPMs for offline installation..."
mkdir -p ~/python311-rpms && cd ~/python311-rpms
sudo dnf download --resolve -y python3.11 python3.11-libs mpdecimal python3.11-pip-wheel python3.11-setuptools-wheel
cd ~ && tar -czf python311-offline.tar.gz python311-rpms/

echo "Pulling Python wheels (including PyTorch and HuggingFace) for the Inference worker..."
mkdir -p ~/py-wheels
pip3.11 download iii-sdk==0.12.0 watchfiles transformers gguf accelerate -d ~/py-wheels
pip3.11 download torch --index-url https://download.pytorch.org/whl/cpu -d ~/py-wheels
tar -czf py-wheels.tar.gz py-wheels/

echo "Fetching the Gemma GGUF model and packing the Hugging Face cache..."
pip3.11 install huggingface_hub
export PATH=$PATH:~/.local/bin
huggingface-cli download ggml-org/gemma-3-270m-GGUF gemma-3-270m-Q8_0.gguf
tar -czf hf-cache.tar.gz .cache/huggingface/

# ==========================================
# 3. DEPLOY & CONFIGURE CALLER VM
# ==========================================
echo "Pushing the Caller payload to $CALLER_IP..."
ssh -i $SSH_KEY -o StrictHostKeyChecking=no ec2-user@$CALLER_IP "mkdir -p ~/app /home/ec2-user/.local/bin"
scp -i $SSH_KEY ~/.local/bin/iii node-v20.tar.xz caller-dist.tar.gz ec2-user@$CALLER_IP:~

echo "Executing offline setup on the Caller VM..."
ssh -i $SSH_KEY ec2-user@$CALLER_IP "bash -s" << EOF
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
    sudo bash -c "cat > /etc/systemd/system/iii-engine.service << 'SYS'
[Unit]
Description=III Engine
[Service]
ExecStart=/home/ec2-user/.local/bin/iii engine start --config /home/ec2-user/app/engine.yaml
Restart=always
User=ec2-user
[Install]
WantedBy=multi-user.target
SYS"

    # Setup Systemd for Caller Worker
    sudo bash -c "cat > /etc/systemd/system/caller-worker.service << 'SYS'
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
SYS"

    sudo systemctl daemon-reload
    sudo systemctl enable --now iii-engine.service caller-worker.service
EOF

# ==========================================
# 4. DEPLOY & CONFIGURE INFERENCE VM
# ==========================================
echo "Pushing the Inference payload to $INFERENCE_IP..."
ssh -i $SSH_KEY -o StrictHostKeyChecking=no ec2-user@$INFERENCE_IP "mkdir -p ~/app/workers/inference-worker /home/ec2-user/.local/bin"
scp -i $SSH_KEY python311-offline.tar.gz py-wheels.tar.gz hf-cache.tar.gz ~/app/workers/inference-worker/inference_worker.py ec2-user@$INFERENCE_IP:~

echo "Executing offline setup and swap configuration on the Inference VM..."
ssh -i $SSH_KEY ec2-user@$INFERENCE_IP "bash -s" << EOF
    # Setup Swap to prevent OOM
    if [ ! -f /swapfile ]; then
        sudo dd if=/dev/zero of=/swapfile bs=1M count=4096
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
    fi

    # Offline Python Install
    tar -xzf ~/python311-offline.tar.gz
    sudo dnf localinstall -y --disablerepo="*" python311-rpms/*.rpm
    
    # Offline Pip Install
    tar -xzf ~/py-wheels.tar.gz
    pip3.11 install --no-index --find-links=py-wheels py-wheels/*
    
    # Extract App & Cache
    tar -xzf ~/hf-cache.tar.gz
    mv ~/inference_worker.py ~/app/workers/inference-worker/

    # Inject optimized code changes (max_new_tokens=5 & print statements)
    sed -i 's/max_new_tokens=100/max_new_tokens=5/' ~/app/workers/inference-worker/inference_worker.py
    sed -i '/def run_inference_handler/a \    print("REQUEST RECEIVED: Starting generation...", flush=True)' ~/app/workers/inference-worker/inference_worker.py 

    # Setup Systemd
    sudo bash -c "cat > /etc/systemd/system/inference-worker.service << 'SYS'
[Unit]
Description=Inference Worker
[Service]
WorkingDirectory=/home/ec2-user/app/workers/inference-worker
Environment=III_URL=ws://$CALLER_IP:49134
Environment=HF_HUB_OFFLINE=1
Environment=OMP_NUM_THREADS=1
ExecStart=/usr/bin/python3.11 inference_worker.py
Restart=always
User=ec2-user
[Install]
WantedBy=multi-user.target
SYS"

    sudo systemctl daemon-reload
    sudo systemctl enable --now inference-worker.service
EOF

echo "Deployment complete. The Nginx gateway is now listening on port 80."
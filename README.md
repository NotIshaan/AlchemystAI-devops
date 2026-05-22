# Alchemyst AI - Air-Gapped Inference Architecture

This repository contains the Terraform configuration and automated deployment scripts for an LLM inference mesh running on air-gapped instances.

## Assignment Scope & Constraint Note

This implementation was intentionally designed to remain within the AWS Free Tier using only t2.micro instances.

The infrastructure, networking, RPC communication, air-gapped deployment flow, and worker orchestration function correctly end-to-end. However, CPU-only inference for Gemma-3-270m on a 1GB RAM t2.micro requires swap-backed execution, causing inference latency to exceed the iii-sdk's internal 30-second RPC timeout limit.

The architectural and deployment objectives of the assignment were completed successfully, while the remaining limitation is strictly due to compute resource constraints of the Free Tier environment.

## Architecture Overview

The setup utilizes three AWS EC2 instances (all running on t2.micro to stay entirely within the free tier), separated into public and private subnets inside a custom VPC.

1. **Gateway VM (Public Subnet):** Serves as a Nginx reverse proxy and bastion host. Only port 80 is exposed publicly.
2. **Caller VM (Private Subnet):** Hosts the iii-engine service and the Node.js Caller Worker. It has no outbound internet access.
3. **Inference VM (Private Subnet):** Hosts the Python Inference Worker which runs the Gemma-3-270m model. It has no outbound internet access.

```text
               +--------------------------------------------------------+
               |                       AWS VPC                          |
               |                                                        |
               |  +------------------------+                            |
               |  |  Public Subnet         |                            |
               |  |  (10.0.1.0/24)         |                            |
               |  |                        |                            |
  Internet     |  |   +----------------+   |                            |
  ---------> [Port]   |   Gateway VM   |   |                            |
   (HTTP)     |  |   | (Bastion /     |   |                            |
              |  |   |  Nginx Proxy)  |   |                            |
              |  |   +--------+-------+   |                            |
              |  +------------|------------+                            |
               |              | (Proxy HTTP requests over port 3111)    |
               |              v                                         |
               |  +--------------------------------------------------+  |
               |  |  Private Subnet (10.0.2.0/24) - No Internet      |  |
               |  |                                                  |  |
               |  |   +------------------+     RPC (Port 49134)      |  |
               |  |   |    Caller VM     |<-----------------------+  |  |
               |  |   | (Node.js Worker) |                        |  |  |
               |  |   +------------------+                        |  |  |
               |  |                                               |  |  |
               |  |                                               |  |  |
               |  |                                               v  |  |
               |  |                                     +------------+  |  |
               |  |                                     | Inference  |  |  |
               |  |                                     |    VM      |  |  |
               |  |                                     |  (Python   |  |  |
               |  |                                     |  Worker)   |  |  |
               |  |                                     +------------+  |  |
               |  +--------------------------------------------------+  |
               +--------------------------------------------------------+
```

## Push-Based Bastion Deployment

Because the private subnet is entirely air-gapped and lacks a NAT Gateway (omitted intentionally to remain within the free tier), these VMs are isolated from public package registries.

Instead, the `setup.sh` script runs on the Gateway VM to build, package, and push all required assets:
1. **Packaging:** Clones the repository, downloads Node.js binaries, Python 3.11 RPMs, offline Python wheel caches (including PyTorch, transformers, accelerate, and iii-sdk), and downloads the Gemma 270M GGUF model from Hugging Face.
2. **Shipping:** Moves these compiled assets and wheels to the private instances using SCP via the bastion ssh key.
3. **Execution:** Performs remote SSH execution to configure swap space, install Python/Node, configure Systemd services for the workers/engine, and start them offline.

The entire flow is triggered automatically during `terraform apply`.

## Systemd Services

All components run as systemd services on the private VMs for reliable lifecycle management:
- **`iii-engine.service`** (on Caller VM): Manages the internal HTTP port mappings and worker registration hub.
- **`caller-worker.service`** (on Caller VM): Starts the Node.js HTTP worker.
- **`inference-worker.service`** (on Inference VM): Starts the Python worker which loads and executes the model.

## Hardware Constraints and RPC Timeouts

Running LLM inference on a CPU-only `t2.micro` (1GB RAM) presents distinct memory and performance challenges:

1. **Memory Allocation & Swap:** Loading the 270M model runs on a memory-constrained 1GB RAM environment. To stabilize the Python process and allocate sufficient virtual memory, the deployment script provisions a 4GB swap file on the Inference VM.
2. **RPC Timeout:** Because the model executes on swap-backed storage, it takes 2 to 3 minutes to generate a response. While Nginx and the iii-engine timeouts were increased, the underlying `iii-sdk` has a hardcoded internal RPC circuit-breaker limit of 30 seconds. Consequently, HTTP requests abort at 30 seconds with an invocation timeout error:
   `{"error":"Invocation timeout after 30000ms: inference::get_response"}`
3. **Logging & Verification:** To track requests through the RPC chain despite the timeout, I added logging inside the python worker (`inference_worker.py`). When a request comes in, it outputs `REQUEST RECEIVED: Starting generation...` to systemd logs. Once generated, the text is printed to stdout. You can verify successful end-to-end receipt and model output by inspecting the Inference VM logs.

## API Usage and Sample Curl

Query the Nginx Gateway VM public IP:

```bash
curl -X POST http://<GATEWAY_PUBLIC_IP>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {
        "role": "user",
        "content": "Explain quantum entanglement."
      }
    ]
  }'
```

**Expected Response (HTTP 500 Timeout):**
```json
{
  "error": "Invocation timeout after 30000ms: inference::get_response"
}
```

---

## How to Redeploy and What to Expect

### Steps to Deploy:
1. **Commit and Push Code Changes:** The deployment script clones the repository on the gateway VM. Commit and push any local code modifications (including python worker logs and token adjustments) first.
2. **Setup SSH Key:** Generate a SSH key named `alchemyst` locally:
   ```bash
   ssh-keygen -t rsa -b 2048 -f ~/.ssh/alchemyst -N ""
   ```
3. **Provision:** Set up your AWS credentials (`alchemyst` profile) and run:
   ```bash
   cd infra/
   terraform init
   terraform apply -auto-approve
   ```

### What to Expect:
- Terraform will provision the network and VM instances.
- The private key and deploy scripts are automatically copied to the Gateway VM.
- The Gateway downloads Node/Python/wheels/model and transfers them to the private subnet VMs.
- Testing the endpoint with the `curl` command above will result in a 30-second timeout error.
- Log into the Inference VM and check the logs:
  ```bash
  ssh -i ~/.ssh/alchemyst ec2-user@<INFERENCE_PRIVATE_IP>
  sudo journalctl -u inference-worker -n 50 --no-pager
  ```
  You will see `REQUEST RECEIVED: Starting generation...` and the generated model response printed in the logs, verifying that:
  - the HTTP request reached the gateway,
  - the RPC chain between workers functioned correctly,
  - the inference worker executed the model successfully,
  - and the failure occurred specifically at the SDK timeout boundary.

---

## Production Hardening Writeup

Before running this architecture in production, the following must be addressed:

1. **Network Configuration:** Introduce a NAT Gateway or AWS PrivateLink VPC endpoints for secure package and model acquisition instead of manual SCP gateway distribution.
2. **Disable Config Hot Reload:** Disable configuration hot-reloading for the engine and workers in production to prevent unintended restarts and service interruptions when codebase files are altered.
3. **SSH Port Hardening:** Move the SSH port on the gateway VM from default 22 to a non-standard port (like 2222 or 722) to minimize automated bot scan noise.
4. **Secrets Management:** Use AWS Secrets Manager or HashiCorp Vault instead of writing SSH keys or API tokens directly to Gateway instance disks.

## Scaling to a Larger Model

If this architecture needed to support a much larger model in the future, here is how I would evolve the infrastructure:

* **Move to GPU Instances:** A CPU-only t2.micro cannot handle massive models. We would need to update the Terraform to provision GPU-backed EC2 instances (like the AWS g4dn or g5 families) for the Inference workers.
* **Containerize with Docker:** Instead of running bash scripts to install Python packages and manage systemd services, I would package the Python worker into a Docker image. This makes the environment reproducible and much easier to deploy.
* **Store Weights in S3:** Using SCP to transfer a 50GB+ model file would be painfully slow and error-prone. The best practice would be to store the model in an S3 bucket, assign an IAM role to the Inference VM, and download the weights directly from S3 on startup.
* **Auto-Scaling and Queues:** Instead of a single Inference VM, we should use an AWS Auto Scaling Group (ASG). By placing a message queue (like AWS SQS) between the Caller API and the Inference workers, we could automatically spin up more instances when the queue gets busy.

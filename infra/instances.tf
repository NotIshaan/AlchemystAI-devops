resource "aws_key_pair" "main" {
  key_name   = "alchemyst-key-test"
  public_key = file("~/.ssh/alchemyst.pub")
}

resource "aws_instance" "gateway" {
  ami= "ami-02b2c1b57c5105166" 
  instance_type= "t2.micro"
  subnet_id  = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.gateway.id]
  key_name= aws_key_pair.main.key_name

  root_block_device {
    volume_size = 8
  }

  tags = {
    Name = "alchemyst-gateway"
  }
}

resource "aws_instance" "inference_worker" {
  ami= "ami-02b2c1b57c5105166"
  instance_type = "t2.micro"
  subnet_id = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.workers.id]
  key_name= aws_key_pair.main.key_name

  tags = {
    Name = "alchemyst-inference-worker"
  }
}

resource "aws_instance" "caller_worker" {
  ami                    = "ami-02b2c1b57c5105166"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.workers.id]
  key_name               = aws_key_pair.main.key_name

  tags = {
    Name = "alchemyst-caller-worker"
  }
}

resource "null_resource" "deploy" {
  depends_on = [
    aws_instance.gateway,
    aws_instance.caller_worker,
    aws_instance.inference_worker
  ]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file("~/.ssh/alchemyst")
    host        = aws_instance.gateway.public_ip
  }

  # Copy the private key to the Gateway VM
  provisioner "file" {
    source      = "~/.ssh/alchemyst"
    destination = "/home/ec2-user/.ssh/alchemyst"
  }

  # Copy setup.sh to the Gateway VM
  provisioner "file" {
    source      = "${path.module}/../scripts/setup.sh"
    destination = "/home/ec2-user/setup.sh"
  }

  # Run the setup script on the Gateway VM
  provisioner "remote-exec" {
    inline = [
      "chmod 600 /home/ec2-user/.ssh/alchemyst",
      "chmod +x /home/ec2-user/setup.sh",
      "/home/ec2-user/setup.sh ${aws_instance.caller_worker.private_ip} ${aws_instance.inference_worker.private_ip}"
    ]
  }
}

output "gateway_public_ip" {
  value = aws_instance.gateway.public_ip
}
output "inference_worker_private_ip" {
  value = aws_instance.inference_worker.private_ip
}
output "caller_worker_private_ip" {
  value = aws_instance.caller_worker.private_ip
}
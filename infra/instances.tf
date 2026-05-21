resource "aws_key_pair" "main" {
  key_name   = "alchemyst-key"
  public_key = file("~/.ssh/alchemyst.pub")
}

resource "aws_instance" "gateway" {
  ami= "ami-02b2c1b57c5105166" 
  instance_type= "t2.micro"
  subnet_id  = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.gateway.id]
  key_name= aws_key_pair.main.key_name

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

output "gateway_public_ip" {
  value = aws_instance.gateway.public_ip
}
output "inference_worker_private_ip" {
  value = aws_instance.inference_worker.private_ip
}
output "caller_worker_private_ip" {
  value = aws_instance.caller_worker.private_ip
}
resource "aws_security_group" "gateway"{
    name="alchemyst-gateway-sg"
    description="allow http from internet, outbound"
    vpc_id=aws_vpc.main.id

    ingress{
        from_port=3111
        to_port=3111
        protocol="tcp"
        cidr_blocks=["0.0.0.0/0"]
    }

    ingress{
        from_port=22
        to_port=22
        protocol="tcp"
        cidr_blocks=["0.0.0.0/0"]
    }

    egress{
        from_port=0
        to_port=0
        protocol="-1"
        cidr_blocks=["0.0.0.0/0"]
    }

    tags={
        Name="alchemyst-gateway-sg"
    }
}

resource "aws_security_group" "workers"{
    name="alchemyst-workers-sg"
    description="allow traffic only from within vpc"
    vpc_id=aws_vpc.main.id

    ingress{
        from_port=0
        to_port=0
        protocol="-1"
        cidr_blocks = ["10.0.0.0/16"]
    }
    egress{
        from_port=0
        to_port=0
        protocol="-1"
        cidr_blocks=["0.0.0.0/0"]
    }
    tags={
        Name="alchemyst-workers-sg"
    }

}
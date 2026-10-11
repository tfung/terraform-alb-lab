# Terraform ALB Lab: Step-by-Step Instructions

Build one public endpoint backed by two web servers, then stop one server and observe how the Application Load Balancer (ALB) routes requests to the remaining healthy server.

Allow approximately two hours after completing [AWS setup](AWS_SETUP.md). See [README.md](README.md) for the specifications and learning outcomes.

This is a walkthrough: copy the examples into the indicated files as you work. The Terraform files are not created by this document. Commands run in your local terminal; Terraform creates the infrastructure through AWS APIs.

The lab creates billable resources. Complete the cleanup step when finished.

## Architecture and request flow

```mermaid
flowchart LR
    Browser -->|HTTP :80| ALB
    subgraph VPC
        ALB[Application Load Balancer]
        ALB --> TG[Target group]
        TG --> A[EC2 server A — Availability Zone A]
        TG --> B[EC2 server B — Availability Zone B]
    end
```

The target group is a collection of destinations, not another server. The ALB forwards requests directly to registered targets.

```mermaid
sequenceDiagram
    participant Browser
    participant ALB
    participant Server as Healthy EC2 target
    ALB->>Server: Periodic GET / health check
    Server-->>ALB: HTTP 200
    Browser->>ALB: GET / on port 80
    ALB->>Server: Forward to a healthy target
    Server-->>ALB: Page identifying server A or B
    ALB-->>Browser: HTTP 200 and page
```

## 1. Open the project and select your AWS profile

```sh
cd /Users/thomasfung/src/terraform-alb-lab
export AWS_PROFILE=terraform-lab
aws sts get-caller-identity
terraform version
```

Replace `terraform-lab` if you chose another login profile name. Verify that the identity output shows your intended learning account and IAM user, rather than root.

We use **Ohio (`us-east-2`)** throughout this walkthrough. Select Ohio in the AWS console too.

## 2. Make your browser login available to Terraform

Some development tools need a compatibility profile to use credentials from `aws login`. Use AWS's documented `credential_process` bridge:

```sh
aws configure set credential_process \
  'aws configure export-credentials --profile terraform-lab --format process' \
  --profile terraform-provider

aws configure set region us-east-2 --profile terraform-provider

export AWS_PROFILE=terraform-provider
aws sts get-caller-identity
```

`terraform-provider` asks the AWS CLI for temporary credentials from your existing `terraform-lab` login. Replace the login profile name inside the quoted command if yours differs. Use two distinct names; a process profile must not point back to itself.

Set `AWS_PROFILE=terraform-provider` again in each new terminal. If your session expires, renew the underlying login with `aws login --profile terraform-lab`.

Reference: [AWS browser-login and process-credentials documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

## 3. Create the project files

If you ran `terraform init` before creating the configuration, you may see:

```text
Terraform initialized in an empty directory!

The directory has no Terraform configuration files.
```

This means Terraform is installed and can run, but the current directory has no `.tf` configuration to initialize. It has not downloaded the AWS provider or created AWS resources. Continue below to create and populate the files, then run `terraform init` again in step 4.

```sh
touch main.tf variables.tf outputs.tf .gitignore
```

`touch` creates empty files; it does not add Terraform configuration. Open them in your editor and save the contents shown below. Add the variable definition to `variables.tf` in this step and the provider configuration to `main.tf` in step 4. Leave `outputs.tf` empty until step 8.

Put this in `.gitignore`:

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
crash.log
```

State records the resources Terraform manages. Keep it locally until cleanup is complete; do not commit it.

Put this in `variables.tf`:

```hcl
variable "aws_region" {
  description = "AWS region for the lab"
  type        = string
  default     = "us-east-2"
}
```

## 4. Configure Terraform and the AWS provider

Start `main.tf` with:

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = "terraform-alb-lab"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
```

The provider is Terraform's adapter for AWS. A data source reads existing AWS information; this one lists available zones. Resource blocks in later steps create infrastructure. References such as `aws_vpc.lab.id` tell Terraform how resources depend on one another.

After saving `variables.tf` and `main.tf`, run these commands from the project directory:

```sh
terraform init
terraform validate
```

This time, `init` should download the HashiCorp AWS provider, and validation should report that the configuration is valid. If initialization still reports an empty directory, check that you are in `terraform-alb-lab` and that your files are saved with `.tf` extensions rather than `.tf.txt`.

Initialization downloads the provider; it does not create infrastructure. Keep the generated `.terraform.lock.hcl` in Git to record the selected provider version.

## 5. Add the network

Append to `main.tf`:

```hcl
resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "alb-lab"
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = cidrsubnet(aws_vpc.lab.cidr_block, 8, count.index + 1)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "alb-lab-public-${count.index + 1}"
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

- **VPC:** your isolated network.
- **Subnets:** two sections of the network in different Availability Zones.
- **Internet gateway:** the network's internet connection.
- **Route table:** directs internet-bound traffic to that gateway.
- **`count = 2`:** creates two copies, indexed by `0` and `1`.
- **`cidrsubnet`:** produces `10.0.1.0/24` and `10.0.2.0/24`.

An ALB needs subnets in at least two Availability Zones. [AWS ALB requirements](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancers.html).

```sh
terraform fmt
terraform validate
terraform plan
```

Read the proposed network resources. Wait to apply until step 9, when the whole configuration is ready.

## 6. Add the security groups

Append to `main.tf`:

```hcl
resource "aws_security_group" "alb" {
  name_prefix = "alb-lab-alb-"
  description = "Public HTTP access to the ALB"
  vpc_id      = aws_vpc.lab.id
}

resource "aws_security_group" "web" {
  name_prefix = "alb-lab-web-"
  description = "HTTP access from the ALB"
  vpc_id      = aws_vpc.lab.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "web_outbound" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

Security groups are stateful firewall rules. The ALB accepts public HTTP and forwards it to the servers. Servers accept HTTP only from the ALB's security group, and can make outbound requests to download packages. Return traffic is automatically allowed. This lab does not open SSH.

## 7. Add the two web servers

Append to `main.tf`:

```hcl
data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "web" {
  count = 2

  ami                         = data.aws_ssm_parameter.amazon_linux.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public[count.index].id
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf install -y nginx
    echo '<h1>Hello from server ${count.index == 0 ? "A" : "B"}</h1>' > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOF

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tags = {
    Name = "alb-lab-server-${count.index == 0 ? "A" : "B"}"
  }

  depends_on = [
    aws_route_table_association.public,
    aws_vpc_security_group_egress_rule.web_outbound
  ]
}
```

An AMI is the operating-system image. The public SSM parameter supplies Amazon Linux's AMI ID for your region. User data runs at first boot, installs Nginx, and writes a page identifying the server.

The instances have encrypted disks and require IMDSv2 for metadata requests. Standard CPU credits avoid surplus-credit billing for these burstable instances. Their public IPs allow package downloads; incoming HTTP remains restricted to the ALB.

The explicit dependency ensures outbound routing and its firewall rule exist before installation starts. Updating user data replaces the instances, allowing the new startup script to run. The latest-AMI parameter can also change between plans; review replacement actions before applying again.

Reference: [AWS public AMI parameters](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-ami.html).

## 8. Add the ALB and outputs

Append to `main.tf`:

```hcl
resource "aws_lb" "lab" {
  name               = "terraform-alb-lab"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "web" {
  name     = "alb-lab-web"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.lab.id

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "web" {
  count = 2

  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.lab.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
```

Put this in `outputs.tf`:

```hcl
output "alb_url" {
  description = "Public URL for the lab"
  value       = "http://${aws_lb.lab.dns_name}"
}

output "instance_ids" {
  description = "EC2 instance IDs for the failure experiment"
  value       = aws_instance.web[*].id
}
```

The listener accepts HTTP. The target group identifies destinations; attachments register the servers. Health checks request `/` and expect HTTP 200. `[*]` collects a value from every resource in a list.

## 9. Review and deploy

```sh
terraform fmt
terraform validate
terraform plan
terraform apply
```

Review what Terraform will create, then enter `yes` when prompted. Deployment and server startup take several minutes. A successful apply does not necessarily mean startup scripts have finished or targets are healthy yet.

```sh
terraform output -raw alb_url
```

Open the URL in a browser. Then send independent requests:

```sh
ALB_URL=$(terraform output -raw alb_url)

for i in $(seq 1 20); do
  curl --fail --silent --show-error "$ALB_URL"
  printf '\n'
done
```

**Success:** HTTP 200 responses identify both servers over multiple requests. They do not need to alternate perfectly or produce an exact 50/50 split.

If the page fails initially, open **EC2 → Target Groups → alb-lab-web → Targets** and inspect health. Wait for boot and package installation. For persistent failures, check routing, security group rules, and startup output in **EC2 → Instances → Actions → Monitor and troubleshoot → Get system log**. System logs may include cloud-init output; detailed user-data output is stored on the instance in `/var/log/cloud-init-output.log`.

## 10. Test a failure and recovery

1. Confirm both registered targets are healthy.
2. Open **EC2 → Instances** in Ohio.
3. Select **alb-lab-server-A** and choose **Instance state → Stop instance**.
4. Watch its health status in the target group.
5. Repeat the requests from step 9.
6. Start A again and observe it return to healthy status.

**Success:** after the failure is detected, requests continue through server B. Some requests may fail during detection. Restarting A restores the second target after health checks pass; Nginx starts again because we enabled its service.

This demonstrates traffic recovery, not automatic server replacement. Keep one target healthy: if all targets are unhealthy, an ALB can fail open and route to unhealthy targets. [AWS health-check behavior](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html).

Optionally, try HTTP directly against an instance's public IP with a short timeout. It should fail because its security group accepts HTTP only from the ALB:

```sh
curl --connect-timeout 5 http://INSTANCE_PUBLIC_IP
```

Replace `INSTANCE_PUBLIC_IP` with a lab instance's address.

## 11. Remove the lab

```sh
terraform plan -destroy
terraform destroy
```

Review the resources to delete and enter `yes`. After successful destruction:

```sh
terraform state list
```

**Success:** no managed resources remain in state. Check the Ohio AWS console too: the lab ALB should be gone, EC2 instances terminated, and the lab VPC removed. Terminated instance entries can remain visible temporarily.

Do not delete state before destroying the lab. Stopping instances alone leaves other billable resources running.

## What you should be able to explain afterward

- How a browser request reaches a server through an ALB.
- Why the ALB spans two Availability Zones.
- How routes and security groups solve different problems.
- Why a running instance can still fail application health checks.
- How Terraform resources, data sources, dependencies, outputs, and state fit together.
- Why an ALB can keep serving traffic without automatically replacing a stopped server.

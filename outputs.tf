# Part 8: Add the ALB and outputs (INSTRUCTIONS.md)
output "alb_url" {
  description = "Public URL for the lab"
  value       = "http://${aws_lb.lab.dns_name}"
}

output "instance_ids" {
  description = "EC2 instance IDs for the failure experiment"
  value       = aws_instance.web[*].id
}

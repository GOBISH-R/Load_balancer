output "app_url" {
  description = "Public URL of the load-balanced application."
  value       = "http://${aws_eip.proxy.public_ip}/"
}

output "proxy_public_ip" {
  description = "Elastic IP of the Nginx proxy."
  value       = aws_eip.proxy.public_ip
}

output "backend_private_ips" {
  description = "Private IPs of the backends (not reachable from the internet)."
  value       = { for name, inst in aws_instance.backend : name => inst.private_ip }
}

output "backend_instance_ids" {
  description = "Instance IDs, used to stop/start a backend for the failover test."
  value       = { for name, inst in aws_instance.backend : name => inst.id }
}

output "ssh_proxy" {
  description = "SSH into the proxy."
  value       = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ec2-user@${aws_eip.proxy.public_ip}"
}

output "ssh_backend_1" {
  description = "SSH into backend-1 through the proxy (jump host)."
  value       = "ssh -i ${local_sensitive_file.ssh_private_key.filename} -J ec2-user@${aws_eip.proxy.public_ip} ec2-user@${aws_instance.backend["backend-1"].private_ip}"
}

output "stop_backend_1" {
  description = "Failover test: stop the whole backend-1 instance."
  value       = "aws ec2 stop-instances --region ${var.aws_region} --instance-ids ${aws_instance.backend["backend-1"].id}"
}

output "start_backend_1" {
  description = "Recovery test: start backend-1 again."
  value       = "aws ec2 start-instances --region ${var.aws_region} --instance-ids ${aws_instance.backend["backend-1"].id}"
}

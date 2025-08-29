output "public_ip" {
  value       = var.attach_eip ? aws_eip.ip[0].public_ip : aws_instance.clms.public_ip
  description = "Public IP for the instance"
}

output "ssh_user" {
  value       = "ubuntu"
  description = "Default SSH username for Ubuntu AMIs"
}

output "ssh_command" {
  value       = "ssh -i <your_private_key> ubuntu@${var.attach_eip ? aws_eip.ip[0].public_ip : aws_instance.clms.public_ip}"
  description = "Example SSH command (replace key path)"
}

output "remote_path" {
  value       = var.remote_path
  description = "Deployment directory created on the server"
}

output "https_url" {
  value = format(
    "https://%s",
    length(try(trimspace(var.domain_name), "")) > 0 ? try(trimspace(var.domain_name), "") : (
      length(trimspace(aws_instance.clms.public_dns)) > 0 ? aws_instance.clms.public_dns : (
        var.attach_eip ? aws_eip.ip[0].public_ip : aws_instance.clms.public_ip
      )
    )
  )
  description = "HTTPS URL for the public entrypoint (Traefik). Prefers domain_name, then instance public DNS, else public IP."
}

output "host" {
  value = length(try(trimspace(var.domain_name), "")) > 0 ? try(trimspace(var.domain_name), "") : (
    length(trimspace(aws_instance.clms.public_dns)) > 0 ? aws_instance.clms.public_dns : (
      var.attach_eip ? aws_eip.ip[0].public_ip : aws_instance.clms.public_ip
    )
  )
  description = "Primary host for the app (domain_name if set, else instance public DNS, else public IP)"
}

output "ssh_host" {
  value       = var.attach_eip ? aws_eip.ip[0].public_ip : aws_instance.clms.public_ip
  description = "Host to use for SSH (public IP/EIP)"
}

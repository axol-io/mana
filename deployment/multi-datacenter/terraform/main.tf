terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

# Multi-cloud provider configuration
provider "aws" {
  region = var.aws_primary_region
  alias  = "primary"
}

provider "aws" {
  region = var.aws_secondary_region
  alias  = "secondary"
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "azurerm" {
  features {}
}

# Variables
variable "aws_primary_region" {
  description = "Primary AWS region"
  default     = "us-west-2"
}

variable "aws_secondary_region" {
  description = "Secondary AWS region"
  default     = "us-east-1"
}

variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  default     = "europe-west1"
}

variable "environment" {
  description = "Environment name"
  default     = "production"
}

variable "node_count_per_datacenter" {
  description = "Number of Mana nodes per datacenter"
  default     = 3
}

# Data sources for availability zones
data "aws_availability_zones" "primary" {
  provider = aws.primary
  state    = "available"
}

data "aws_availability_zones" "secondary" {
  provider = aws.secondary
  state    = "available"
}

# AWS Primary Datacenter (us-west-2)
module "aws_primary_datacenter" {
  source = "./modules/aws-datacenter"
  
  providers = {
    aws = aws.primary
  }
  
  region              = var.aws_primary_region
  availability_zones  = data.aws_availability_zones.primary.names
  environment        = var.environment
  datacenter_id      = "aws-us-west-2"
  node_count         = var.node_count_per_datacenter
  
  # Ultra-performance instance types
  instance_type = "c6i.4xlarge"  # 16 vCPU, 32GB RAM, 10 Gbps network
  
  # Enable enhanced networking
  enhanced_networking = true
  
  # Storage optimized for performance
  root_volume_type = "gp3"
  root_volume_size = 200
  root_volume_iops = 3000
  
  data_volume_type = "gp3" 
  data_volume_size = 1000
  data_volume_iops = 10000
  
  tags = {
    Environment     = var.environment
    Datacenter     = "aws-us-west-2"
    UltraPerformance = "true"
    ManaCluster    = "primary"
  }
}

# AWS Secondary Datacenter (us-east-1)
module "aws_secondary_datacenter" {
  source = "./modules/aws-datacenter"
  
  providers = {
    aws = aws.secondary
  }
  
  region              = var.aws_secondary_region
  availability_zones  = data.aws_availability_zones.secondary.names
  environment        = var.environment
  datacenter_id      = "aws-us-east-1"
  node_count         = var.node_count_per_datacenter
  
  instance_type = "c6i.4xlarge"
  enhanced_networking = true
  
  root_volume_type = "gp3"
  root_volume_size = 200
  root_volume_iops = 3000
  
  data_volume_type = "gp3"
  data_volume_size = 1000
  data_volume_iops = 10000
  
  tags = {
    Environment     = var.environment
    Datacenter     = "aws-us-east-1"
    UltraPerformance = "true"
    ManaCluster    = "secondary"
  }
}

# GCP Datacenter (europe-west1)
module "gcp_datacenter" {
  source = "./modules/gcp-datacenter"
  
  project_id      = var.gcp_project_id
  region         = var.gcp_region
  environment    = var.environment
  datacenter_id  = "gcp-europe-west1"
  node_count     = var.node_count_per_datacenter
  
  # Ultra-performance machine type
  machine_type = "c2-standard-16"  # 16 vCPU, 64GB RAM
  
  # High-performance persistent disks
  boot_disk_type = "pd-ssd"
  boot_disk_size = 200
  
  data_disk_type = "pd-ssd"
  data_disk_size = 1000
  
  labels = {
    environment       = var.environment
    datacenter       = "gcp-europe-west1"
    ultra-performance = "true"
    mana-cluster     = "tertiary"
  }
}

# Global Load Balancer and Traffic Management
resource "aws_route53_zone" "main" {
  provider = aws.primary
  name     = "mana.ethereum.local"
  
  tags = {
    Environment = var.environment
    Purpose     = "Multi-datacenter DNS"
  }
}

# Health checks for each datacenter
resource "aws_route53_health_check" "aws_primary" {
  provider                        = aws.primary
  fqdn                           = module.aws_primary_datacenter.load_balancer_dns
  port                           = 80
  type                           = "HTTP"
  resource_path                  = "/health"
  failure_threshold              = "3"
  request_interval               = "30"
  measure_latency               = true
  enable_sni                    = false
  
  tags = {
    Name = "AWS Primary Health Check"
    Environment = var.environment
  }
}

resource "aws_route53_health_check" "aws_secondary" {
  provider                        = aws.primary
  fqdn                           = module.aws_secondary_datacenter.load_balancer_dns
  port                           = 80
  type                           = "HTTP"
  resource_path                  = "/health"
  failure_threshold              = "3"
  request_interval               = "30"
  measure_latency               = true
  
  tags = {
    Name = "AWS Secondary Health Check"
    Environment = var.environment
  }
}

# Weighted routing with health checks
resource "aws_route53_record" "primary" {
  provider = aws.primary
  zone_id  = aws_route53_zone.main.zone_id
  name     = "api"
  type     = "CNAME"
  ttl      = 60
  
  weighted_routing_policy {
    weight = 100
  }
  
  set_identifier  = "aws-primary"
  records        = [module.aws_primary_datacenter.load_balancer_dns]
  health_check_id = aws_route53_health_check.aws_primary.id
}

resource "aws_route53_record" "secondary" {
  provider = aws.primary
  zone_id  = aws_route53_zone.main.zone_id
  name     = "api"
  type     = "CNAME"
  ttl      = 60
  
  weighted_routing_policy {
    weight = 50
  }
  
  set_identifier  = "aws-secondary"
  records        = [module.aws_secondary_datacenter.load_balancer_dns]
  health_check_id = aws_route53_health_check.aws_secondary.id
}

# Cross-datacenter VPN connections
resource "aws_vpc_peering_connection" "primary_to_secondary" {
  provider    = aws.primary
  vpc_id      = module.aws_primary_datacenter.vpc_id
  peer_vpc_id = module.aws_secondary_datacenter.vpc_id
  peer_region = var.aws_secondary_region
  auto_accept = false
  
  tags = {
    Name = "Primary to Secondary VPC Peering"
    Environment = var.environment
  }
}

resource "aws_vpc_peering_connection_accepter" "secondary" {
  provider                  = aws.secondary
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_secondary.id
  auto_accept              = true
  
  tags = {
    Name = "Accept Primary to Secondary Peering"
    Environment = var.environment
  }
}

# Inter-datacenter security groups for CRDT replication
resource "aws_security_group" "inter_datacenter" {
  provider    = aws.primary
  name_prefix = "mana-inter-datacenter-"
  vpc_id      = module.aws_primary_datacenter.vpc_id
  
  # Allow CRDT replication traffic
  ingress {
    from_port   = 8087
    to_port     = 8087
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "AntidoteDB inter-datacenter replication"
  }
  
  # Allow consensus communication
  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "Ethereum consensus inter-datacenter"
  }
  
  # Allow monitoring
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "Prometheus metrics"
  }
  
  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "Mana Inter-Datacenter Security Group"
    Environment = var.environment
  }
}

# Outputs for multi-datacenter coordination
output "datacenter_endpoints" {
  description = "Endpoints for each datacenter"
  value = {
    aws_primary = {
      load_balancer = module.aws_primary_datacenter.load_balancer_dns
      vpc_id       = module.aws_primary_datacenter.vpc_id
      region       = var.aws_primary_region
    }
    aws_secondary = {
      load_balancer = module.aws_secondary_datacenter.load_balancer_dns
      vpc_id       = module.aws_secondary_datacenter.vpc_id
      region       = var.aws_secondary_region
    }
    gcp_primary = {
      load_balancer = module.gcp_datacenter.load_balancer_ip
      network      = module.gcp_datacenter.network_name
      region       = var.gcp_region
    }
  }
}

output "global_dns" {
  description = "Global DNS endpoint"
  value       = "api.${aws_route53_zone.main.name}"
}

output "monitoring_endpoints" {
  description = "Monitoring endpoints for each datacenter"
  value = {
    aws_primary_grafana   = "http://${module.aws_primary_datacenter.load_balancer_dns}:3000"
    aws_secondary_grafana = "http://${module.aws_secondary_datacenter.load_balancer_dns}:3000"
    gcp_grafana          = "http://${module.gcp_datacenter.load_balancer_ip}:3000"
  }
}
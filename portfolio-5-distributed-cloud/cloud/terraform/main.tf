# =====================================================================
# Portfolio 5 - SeunBaba production data tier on AWS (af-south-1, Cape Town)
# STATUS: DESIGN ONLY. This file was written as infrastructure-as-code to
# document the target deployment. It has NOT been applied and has NOT been
# run through `terraform validate` (the Terraform CLI could not be installed
# in the build environment). Network resources (VPC, subnets) are inputs.
# =====================================================================
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws          = { source = "hashicorp/aws", version = "~> 5.0" }
    mongodbatlas = { source = "mongodb/mongodbatlas", version = "~> 1.15" }
  }
}

provider "aws" {
  region = "af-south-1"
}

variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }   # one per Availability Zone (3 AZs)
variable "app_security_group" { type = string }         # the API servers' security group
variable "atlas_project_id"   { type = string }
variable "db_password"        {
  type      = string
  sensitive = true                                       # supplied from a secret store, never committed
}

# ---------------------------------------------------------------- network access
resource "aws_db_subnet_group" "seunbaba" {
  name       = "seunbaba-db"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "db" {
  name   = "seunbaba-db"
  vpc_id = var.vpc_id
  ingress {                                              # PostgreSQL only from the application tier
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.app_security_group]
  }
  ingress {                                              # Redis only from the application tier
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.app_security_group]
  }
}

# ---------------------------------------------------------------- PostgreSQL (system of record)
resource "aws_db_parameter_group" "pg16" {
  name   = "seunbaba-pg16"
  family = "postgres16"
  parameter {
    name  = "timezone"
    value = "Africa/Lagos"                               # lesson from Portfolio 4 cross-check
  }
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
    apply_method = "pending-reboot"
  }
}

# Multi-AZ: synchronous standby in a second AZ, automatic failover (~1-2 min DNS switch).
resource "aws_db_instance" "primary" {
  identifier                   = "seunbaba-pg-primary"
  engine                       = "postgres"
  engine_version               = "16"
  instance_class               = "db.r6g.large"
  allocated_storage            = 200
  max_allocated_storage        = 1000
  storage_type                 = "gp3"
  storage_encrypted            = true
  db_name                      = "seunbaba"
  username                     = "seunbaba_admin"
  password                     = var.db_password
  multi_az                     = true
  db_subnet_group_name         = aws_db_subnet_group.seunbaba.name
  vpc_security_group_ids       = [aws_security_group.db.id]
  parameter_group_name         = aws_db_parameter_group.pg16.name
  backup_retention_period      = 14                      # point-in-time recovery window
  backup_window                = "01:00-02:00"           # UTC = 02:00-03:00 WAT, lowest traffic
  maintenance_window           = "sun:02:30-sun:03:30"
  performance_insights_enabled = true
  deletion_protection          = true
  publicly_accessible          = false
}

# Asynchronous read replica for reporting (Portfolio 2 Q3/Q4-type queries) so that
# heavy analytics never compete with checkout on the primary.
resource "aws_db_instance" "reporting_replica" {
  identifier             = "seunbaba-pg-reporting"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = "db.r6g.large"
  storage_encrypted      = true
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.pg16.name
  publicly_accessible    = false
}

# ---------------------------------------------------------------- Redis (cache, carts, flash-sale gate)
resource "aws_elasticache_subnet_group" "seunbaba" {
  name       = "seunbaba-cache"
  subnet_ids = var.private_subnet_ids
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "seunbaba-redis"
  description                = "SeunBaba carts, sessions, leaderboards, flash-sale counters"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.r6g.large"
  num_cache_clusters         = 2                         # primary + replica in another AZ
  automatic_failover_enabled = true
  multi_az_enabled           = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  subnet_group_name          = aws_elasticache_subnet_group.seunbaba.name
  security_group_ids         = [aws_security_group.db.id]
  snapshot_retention_limit   = 3                         # carts survive a full node loss
}

# ---------------------------------------------------------------- MongoDB Atlas (catalogue + order read model)
resource "mongodbatlas_advanced_cluster" "catalogue" {
  project_id   = var.atlas_project_id
  name         = "seunbaba-catalogue"
  cluster_type = "REPLICASET"
  replication_specs {
    region_configs {
      provider_name = "AWS"
      region_name   = "AF_SOUTH_1"
      priority      = 7
      electable_specs {
        instance_size = "M30"
        node_count    = 3                                # same 3-member topology as the local rs0
      }
    }
  }
  backup_enabled = true
}

output "postgres_writer_endpoint"  { value = aws_db_instance.primary.address }
output "postgres_reporting_endpoint" { value = aws_db_instance.reporting_replica.address }
output "redis_primary_endpoint"    { value = aws_elasticache_replication_group.redis.primary_endpoint_address }

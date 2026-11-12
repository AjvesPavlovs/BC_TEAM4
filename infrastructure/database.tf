resource "aws_db_subnet_group" "database" {
  count      = var.enable_database ? 1 : 0
  name       = "${var.project_name}-db-subnets"
  subnet_ids = aws_subnet.database[*].id
}

resource "aws_db_instance" "postgres" {
  count                       = var.enable_database ? 1 : 0
  identifier                  = "${var.project_name}-postgres"
  engine                      = "postgres"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  max_allocated_storage       = 30
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "slicesip"
  username                    = "slicesip_admin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.database[0].name
  vpc_security_group_ids      = [aws_security_group.database.id]
  publicly_accessible        = false
  multi_az                    = false
  backup_retention_period     = 1
  auto_minor_version_upgrade  = true
  deletion_protection         = false # Bootcamp teardown only
  skip_final_snapshot         = true  # Bootcamp teardown destroys data!
  copy_tags_to_snapshot       = true
}

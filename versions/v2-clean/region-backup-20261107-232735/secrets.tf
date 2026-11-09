# Application secrets live in AWS Secrets Manager in the primary region and are replicated to the DR
# region, so a restore from the pgBackRest backups (or a rebuild) is possible while the primary region is down.

resource "random_password" "pg_super" {
  length  = 32
  special = false
}

resource "random_password" "pg_repl" {
  length  = 32
  special = false
}

resource "random_password" "db_app" {
  length  = 32
  special = false
}

resource "random_password" "pgbackrest" {
  length  = 40
  special = false
}

locals {
  secret_names = {
    pg_super   = "${var.name_prefix}/pg-super"
    pg_repl    = "${var.name_prefix}/pg-repl"
    db_app     = "${var.name_prefix}/db-app"
    pgbackrest = "${var.name_prefix}/pgbackrest-pass"
  }
  secret_values = {
    pg_super   = random_password.pg_super.result
    pg_repl    = random_password.pg_repl.result
    db_app     = random_password.db_app.result
    pgbackrest = random_password.pgbackrest.result
  }
}

resource "aws_secretsmanager_secret" "s" {
  for_each                = local.secret_names
  name                    = each.value
  recovery_window_in_days = 0
  replica {
    region = var.dr_region
  }
}

resource "aws_secretsmanager_secret_version" "s" {
  for_each      = local.secret_names
  secret_id     = aws_secretsmanager_secret.s[each.key].id
  secret_string = local.secret_values[each.key]
}

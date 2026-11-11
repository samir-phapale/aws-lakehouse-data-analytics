locals {
  # Athena v3 reads native Delta tables; Redshift Spectrum cannot, so "spectrum" catalogs the
  # curated tables again through symlink manifests the crawler writes into each table
  zones = {
    raw = {
      bucket  = var.raw_bucket_name
      tables  = var.raw_table_paths
      enabled = true
      native  = true
    }
    transformed = {
      bucket  = var.transformed_bucket_name
      tables  = var.transformed_tables
      enabled = var.enable_transformed_zone
      native  = true
    }
    curated = {
      bucket  = var.curated_bucket_name
      tables  = var.curated_tables
      enabled = var.enable_curated_zone
      native  = true
    }
    spectrum = {
      bucket  = var.curated_bucket_name
      tables  = var.curated_tables
      enabled = var.enable_curated_zone
      native  = false
    }
  }
  enabled_zones = { for zone, cfg in local.zones : zone => cfg if cfg.enabled }

  analyst_grants = {
    for pair in setproduct(keys(local.zones), var.analyst_principal_arns) :
    "${pair[0]}|${pair[1]}" => { zone = pair[0], principal = pair[1] }
  }
}

resource "aws_glue_catalog_database" "zone" {
  for_each = local.zones

  name        = "${var.database_prefix}_${each.key}"
  description = "Lakehouse ${each.key} zone (s3://${each.value.bucket}/)"
}

resource "aws_glue_crawler" "zone" {
  for_each = local.enabled_zones

  name                   = "${var.name_prefix}-${each.key}-crawler"
  description            = "Registers the ${each.key} Delta tables in ${aws_glue_catalog_database.zone[each.key].name}"
  role                   = var.crawler_role_arn
  database_name          = aws_glue_catalog_database.zone[each.key].name
  security_configuration = var.security_configuration_name

  delta_target {
    delta_tables              = [for path in each.value.tables : "s3://${each.value.bucket}/${trim(path, "/")}/"]
    write_manifest            = !each.value.native
    create_native_delta_table = each.value.native
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}

resource "aws_athena_workgroup" "this" {
  name          = "${var.name_prefix}-analytics"
  description   = "Queries over the lakehouse catalog; results KMS-encrypted"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${var.results_bucket_name}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
  }
}

resource "aws_athena_named_query" "this" {
  for_each = var.enable_curated_zone ? fileset(var.sql_dir, "*.sql") : toset([])

  name      = trimsuffix(each.value, ".sql")
  workgroup = aws_athena_workgroup.this.id
  database  = aws_glue_catalog_database.zone["curated"].name
  query     = file("${var.sql_dir}/${each.value}")
}

# This account's Lake Formation has no IAMAllowedPrincipals defaults, so every catalog grant is
# explicit. S3 locations are not registered; S3 access stays with IAM and the bucket policies.
resource "aws_lakeformation_permissions" "crawler_database" {
  for_each = local.zones

  principal   = var.crawler_role_arn
  permissions = ["CREATE_TABLE", "ALTER", "DESCRIBE"]

  database {
    name = aws_glue_catalog_database.zone[each.key].name
  }
}

resource "aws_lakeformation_permissions" "crawler_tables" {
  for_each = local.zones

  principal   = var.crawler_role_arn
  permissions = ["ALTER", "DESCRIBE", "SELECT"]

  table {
    database_name = aws_glue_catalog_database.zone[each.key].name
    wildcard      = true
  }
}

resource "aws_lakeformation_permissions" "analyst_database" {
  for_each = local.analyst_grants

  principal   = each.value.principal
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.zone[each.value.zone].name
  }

  # The creating principal gets ALL from Lake Formation; when an analyst is also the deployer the
  # provider would otherwise revoke and re-grant on every plan
  lifecycle {
    ignore_changes = [permissions, permissions_with_grant_option]
  }
}

resource "aws_lakeformation_permissions" "analyst_tables" {
  for_each = local.analyst_grants

  principal   = each.value.principal
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.zone[each.value.zone].name
    wildcard      = true
  }
}

resource "aws_lakeformation_permissions" "spectrum_database" {
  principal   = var.spectrum_role_arn
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.zone["spectrum"].name
  }
}

resource "aws_lakeformation_permissions" "spectrum_tables" {
  principal   = var.spectrum_role_arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.zone["spectrum"].name
    wildcard      = true
  }
}

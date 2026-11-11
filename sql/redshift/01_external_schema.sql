-- Spectrum schema over the curated symlink-manifest tables (Spectrum cannot read native Delta).
-- Placeholders are filled in by Terraform templatefile.
CREATE EXTERNAL SCHEMA IF NOT EXISTS spectrum_curated
FROM DATA CATALOG
DATABASE '${spectrum_database}'
IAM_ROLE '${role_arn}'

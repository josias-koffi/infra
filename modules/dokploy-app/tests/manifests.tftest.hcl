mock_provider "dokploy" {
  mock_resource "dokploy_postgres" {
    defaults = { app_name = "sample-db-x1y2z3" }
  }
  mock_resource "dokploy_redis" {
    defaults = { app_name = "sample-cache-x1y2z3" }
  }
}

run "jobspark_production_compose" {
  command = apply
  module { source = "./tests/harness" }
  variables {
    manifest_path = "../../examples/jobspark/.deploy/manifest.yaml"
    environment   = "production"
  }

  assert {
    condition     = strcontains(output.rendered.compose_env, "VOLUME_PREFIX=jobspark\n")
    error_message = "production must keep the live jobspark_* volumes"
  }
  assert {
    condition     = strcontains(output.rendered.compose_env, "POSTGRES_HOST=jobspark-postgres")
    error_message = "POSTGRES_HOST template"
  }
  assert {
    condition     = output.rendered.backups.db.postgres == "db/production/"
    error_message = "legacy db prefix must be kept"
  }
  assert {
    condition     = output.rendered.backups.volumes.api_data.prefix == "api-data/production/" && output.rendered.backups.volumes.api_data.volume == "jobspark_api_data"
    error_message = "api_data volume backup must target jobspark_api_data under api-data/production/"
  }
  assert {
    condition     = output.rendered.domains.api == "jobspark-api.koklo.dev -> api:3333"
    error_message = "api route"
  }
}

run "jobspark_staging_compose" {
  command = apply
  module { source = "./tests/harness" }
  variables {
    manifest_path = "../../examples/jobspark/.deploy/manifest.yaml"
    environment   = "staging"
  }

  assert {
    condition     = strcontains(output.rendered.compose_env, "VOLUME_PREFIX=cvspark-staging\n")
    error_message = "staging must keep the live cvspark-staging_* volumes"
  }
  assert {
    condition     = strcontains(output.rendered.compose_env, "POSTGRES_HOST=jobspark-staging-postgres")
    error_message = "staging POSTGRES_HOST"
  }
  assert {
    condition     = output.rendered.backups.volumes.api_data.volume == "cvspark-staging_api_data"
    error_message = "staging volume backup"
  }
}

run "jemima_production_compose" {
  command = apply
  module { source = "./tests/harness" }
  variables {
    manifest_path = "../../examples/jemima/.deploy/manifest.yaml"
    environment   = "production"
  }

  assert {
    condition     = strcontains(output.rendered.compose_env, "VOLUME_PREFIX=jemima\n") && strcontains(output.rendered.compose_env, "SITE_DOMAIN=jemima.koklo.dev")
    error_message = "jemima prefix/domains"
  }
  assert {
    condition     = output.rendered.backups.db.postgres == "db/jemima/production/"
    error_message = "jemima gets a default DB backup"
  }
  assert {
    condition     = output.rendered.domains.minio == "jemima-media.koklo.dev -> minio:9000"
    error_message = "media route"
  }
}

run "sample_services" {
  command = apply
  module { source = "./tests/harness" }
  variables {
    manifest_path = "../../examples/sample-services/.deploy/manifest.yaml"
    environment   = "production"
  }

  assert {
    condition     = strcontains(output.rendered.app_env.api, "DATABASE_URL=postgresql://sample:s3cr3t-db_password@sample-db-x1y2z3:5432/sample")
    error_message = "api must receive DATABASE_URL"
  }
  assert {
    condition     = strcontains(output.rendered.app_env.api, "REDIS_URL=redis://default:s3cr3t-cache_password@sample-cache-x1y2z3:6379")
    error_message = "api must receive REDIS_URL"
  }
  assert {
    condition     = strcontains(output.rendered.app_env.web, "API_URL=https://sample-api.example.com") && !strcontains(output.rendered.app_env.web, "DB_PASSWORD")
    error_message = "web: API_URL and only its own secrets"
  }
  assert {
    condition     = output.rendered.backups.db.db == "db/sample/production/db/" && output.rendered.backups.volumes["api:uploads"].volume == "sample-production_uploads"
    error_message = "default backups for db and volume"
  }
}

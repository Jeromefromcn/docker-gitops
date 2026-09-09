# Credentials come from the GOOGLE_APPLICATION_CREDENTIALS env var (a dedicated
# SA key living OUTSIDE this repo) — never inline a key here. The provider
# reads it implicitly; no `credentials` attribute is set on purpose.
provider "google" {
  project = var.project_id
  region  = "us-west1" # free-tier region, hardcoded (see README)
}

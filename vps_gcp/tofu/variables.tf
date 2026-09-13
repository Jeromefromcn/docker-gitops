variable "project_id" {
  description = "GCP project ID that owns the resources."
  type        = string
}

variable "project_number" {
  description = "GCP project NUMBER (digits only) for budget_filter — distinct from project_id (the alphanumeric name)."
  type        = string
}

variable "billing_account" {
  description = "GCP billing account ID (format A1B2C3-D4E5F6-G7H8I9) for the budget; needs roles/billing.costsManager at the BILLING ACCOUNT level, not the project."
  type        = string
}

variable "ssh_public_key" {
  description = "Public SSH key injected as GCP ssh-keys metadata for the ubuntu user, survives destroy→apply. Public key only, not a secret. Empty (default) falls back to Console browser SSH."
  type        = string
  default     = ""
}

variable "project_id" {
  description = "GCP project ID that owns the resources."
  type        = string
}

variable "billing_account" {
  description = "GCP billing account ID (format A1B2C3-D4E5F6-G7H8I9) for the budget; needs roles/billing.costsManager at the BILLING ACCOUNT level, not the project."
  type        = string
}

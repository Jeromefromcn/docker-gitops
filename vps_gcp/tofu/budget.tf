# The budget's permission lives on the BILLING ACCOUNT, not the project —
# `roles/billing.costsManager` must be granted at the billing-account level in
# the console. A project-level role cannot see budgets regardless of scope.
#
# budget_filter.projects expects `projects/{project_NUMBER}` — the digits-only
# numeric id, NOT `projects/{project_id}` (the alphanumeric name). These are
# different GCP identifiers; the budget silently won't match its scope if the
# wrong one is used.
resource "google_billing_budget" "free_tier" {
  billing_account = var.billing_account
  display_name    = "free-tier-guard"
  depends_on      = [google_project_service.billingbudgets, google_project_service.cloudbilling]

  amount {
    specified_amount {
      # This billing account (BOCHK) is denominated in HKD — the API rejects a
      # currency that doesn't match the account. 1 HKD ≈ $0.13 USD, so the
      # threshold sits well inside the free tier. The pre-existing "gcp budget"
      # uses the same HKD 1 cap.
      currency_code = "HKD"
      units         = "1"
    }
  }

  # ~$0.50 and ~$0.90 of the $1.00 cap — an early warning well inside the
  # free tier, not at its edge.
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }

  budget_filter {
    projects = ["projects/${var.project_number}"]
  }
}

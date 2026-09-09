# The budget's permission lives on the BILLING ACCOUNT, not the project —
# `roles/billing.costsManager` must be granted at the billing-account level in
# the console. A project-level role cannot see budgets regardless of scope.
resource "google_billing_budget" "free_tier" {
  billing_account = var.billing_account
  display_name    = "free-tier-guard"

  amount {
    specified_amount {
      currency_code = "USD"
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
    projects = ["projects/${var.project_id}"]
  }
}

# OpenTofu 集成實作計畫（vps_oracle 收編 + vps_gcp 沙盒）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在倉庫裡落一套完整的 OpenTofu IaC——`vps_gcp` greenfield 全生命週期 + `vps_oracle` brownfield 收編，各一份 root module、獨立 state、獨立憑證，外加一份路徑範圍規則檔與 CI 靜態檢查。

**Architecture:** 兩個獨立的 root module（`vps_gcp/tofu/`、`vps_oracle/tofu/`），並存於既有 host-first 目錄結構下，各自 `*.tfstate` 本機 + gitignore。GCP 用專設 service account + key（角色收窄），OCI 用 Instance Principal（磁碟零憑證 + IAM 硬牆）。CI 走靜態檢查（`tofu fmt -check` + `tofu validate`），不碰線上。

**Tech Stack:** OpenTofu 1.12.6、provider `oracle/oci` 9.0.0、provider `hashicorp/google` 8.2.0、GitHub Actions `opentofu/setup-opentofu@v1`（`tofu_version: 1.12.6`）。

**Spec:** [docs/superpowers/specs/2026-09-09-opentofu-integration-design.md](../specs/2026-09-09-opentofu-integration-design.md)（計畫以 spec 為準，執行者要連 spec 一起讀）

## Global Constraints

- **tofu 能做什麼 = 發給它的身分被 IAM 授權做什麼，不多不少。** 最小權限在 IAM 設，不在 Terraform 設。
- **永不可在 `vps_oracle/tofu/` 執行 `tofu destroy`。**（IAM 硬牆已讓它打不到實例，但紅線仍要寫明——縱深防禦。）
- GCP 免費層硬邊界（超出即真金白銀）：e2-micro 僅 us-west1 / us-central1 / us-east1 免費；30 GB 標準永久磁碟總額；每月 1 GB 出網（不含中國與澳洲）。`machine_type`／區域／磁碟大小**寫死字面值、不用變數**。
- 版本釘死：`required_version` 與 `required_providers` 用具體版本，不用範圍、不用 latest。`.terraform.lock.hcl` 必須提交。
- 不提交任何密鑰：`*.tfstate`、`*.tfstate.*`、`.terraform/`、`*.auto.tfvars` 全部 gitignore；GCP key JSON 存倉庫之外，經 `GOOGLE_APPLICATION_CREDENTIALS` 環境變數引用。
- OCI 收編用 `import {}` 區塊（進 git、可 review），不用 `tofu import` 一次性指令。
- 兩份 root module、兩份 state、兩套憑證彼此隔離——OCI 的 state 壞掉不卡 GCP 的工作。
- 英文 commit message（本倉庫慣例）。

---

## 前置條件（blocking，人工在 console 操作，Claude 無法代做）

執行者在開始 Phase 1 的 live 步驟（Task 7）與 Phase 2 的 live 步驟（Task 9–11）前，必須先與使用者逐項確認下列都已完成：

1. **安裝 OpenTofu（arm64）**：使 `tofu` 在宿主機 PATH 上可用，版本 ≥ 1.12（建議 1.12.6）。
2. **OCI**：console 建立 Dynamic Group（匹配這台機的 OCID）+ 一條 policy 只授權 `manage virtual-network-family`。
3. **GCP**：建立專用 service account，賦予 `roles/compute.networkAdmin`、`roles/compute.instanceAdmin.v1`、`roles/serviceusage.serviceUsageAdmin` 三個角色，產生 key JSON 放到倉庫之外。
4. **GCP 帳單帳戶（最易踩空）**：`google_billing_budget` 的權限掛在**帳單帳戶**上、不是專案上，需在帳單帳戶層級授予 `roles/billing.costsManager`（或等效）。專案層級角色再全也管不到預算。

> Claude 可以為上述每一項準備好確切的 console 點位／指令，但實際授權動作必須由使用者完成。live apply/import 任務（Task 7、9、10、11）的 Step 1 都以「確認前置條件已就緒」開始。

---

### Task 1: 倉庫護欄——`.gitignore` + `tofu-conventions.md`

**Files:**
- Modify: `.gitignore`（末尾追加 4 行）
- Create: `.claude/rules/tofu-conventions.md`

**Interfaces:**
- Produces: 規則檔 `.claude/rules/tofu-conventions.md`（`paths: */tofu/**`，後續所有任務的 `.tf` 改動受其約束）；`.gitignore` 的 state/tfvars 排除（後續任務產生的 `*.tfstate` / `.auto.tfvars` 才不會被誤提）。

- [ ] **Step 1: 在 `.gitignore` 末尾追加**

```gitignore
# OpenTofu (vps_oracle/tofu, vps_gcp/tofu)
*.tfstate
*.tfstate.*
.terraform/
*.auto.tfvars
```

- [ ] **Step 2: 寫 `.claude/rules/tofu-conventions.md`**（格式對齊現有 `compose-conventions.md` / `k3s-gitops.md`：frontmatter `paths:` + 中文內文）

```markdown
---
paths:
  - "*/tofu/**"
---

# OpenTofu 约定

编写或修改任何 `<host>/tofu/` 下的 .tf 文件时必须遵守。这里是唯一权威，README 只做指引。

## 红线

> **禁止在 `vps_oracle/tofu/` 执行 `tofu destroy`。**

OCI 侧 IAM 已不授予 `manage instance-family`，`destroy` 打不到运算实例；但红线仍要写明——纵深防御，对人、对 Claude 都是同一份说明。GCP 侧 `vps_gcp/tofu/` 的 destroy 是设计目标，不受此限。

## 版本

- `versions.tf` 里 `required_version` 与 `required_providers` 钉死具体版本，不用范围、不用 latest。
- `.terraform.lock.hcl` 是纳管文件，**必须提交**——锁 provider 版本与 checksum，跟 compose 钉死 image tag/digest 同理。

## State 与机密

- `*.tfstate`、`*.tfstate.*`、`.terraform/`、`*.auto.tfvars` 一律不提交（已在 `.gitignore`）。
- `.auto.tfvars` 只放身份类值（GCP 的 `project_id` / `billing_account`；OCI 的 OCID / compartment / region），不放 key。key 放仓库之外，经环境变量引用（GCP `GOOGLE_APPLICATION_CREDENTIALS`）。
- 不在任何 `.tf` 里内联密钥、key、token。

## 认证

- OCI 用 Instance Principal：`auth = "InstancePrincipal"`，磁盘零长期凭据。Dynamic Group + policy 在 console 建，不在仓库。
- GCP 用专设 service account + key JSON，角色收窄（networkAdmin / instanceAdmin.v1 / serviceusage.serviceUsageAdmin），key 存仓库外。

## 收编与免费层

- OCI 收编用 `import {}` 区块（进 git、可 review），不用 `tofu import` 一次性指令。
- GCP 免费层是硬边界：`machine_type`、区域、磁盘大小写死字面值、不用变量；第一批资源就含 `google_billing_budget`。
```

- [ ] **Step 3: 自我驗證規則檔 frontmatter 格式**（與 `compose-conventions.md` 一致的 YAML `paths:`）

Run: `head -6 .claude/rules/tofu-conventions.md`（應看到 `---` / `paths:` / `  - "*/tofu/**"` / `---`）

- [ ] **Step 4: Commit**

```bash
git add .gitignore .claude/rules/tofu-conventions.md
git commit -m "chore: add OpenTofu conventions rule and gitignore state/tfvars"
```

---

### Task 2: CI 靜態檢查——`tofu` job

**Files:**
- Modify: `.github/workflows/repo-conventions.yml`（`paths` 觸發 + 新增 job）

**Interfaces:**
- Consumes: Task 1 的 `*/tofu/**` 目錄（本任務落地時尚無 `.tf`，`find` 找不到目錄、迴圈空轉、exit 0）。
- Produces: CI job `tofu`，之後所有任務新增的 `.tf` 檔受 `fmt -check` + `validate` 把關。

- [ ] **Step 1: 擴充 `paths` 觸發**（`push` 與 `pull_request` 兩處都加，指向 `'*/tofu/**'`）

```yaml
    paths:
      - '*/compose/**/docker-compose.yml'
      - 'vps_oracle/host-native/inspector/**'
      - '*/tofu/**'
      - '.github/scripts/**'
      - '.github/workflows/repo-conventions.yml'
```

- [ ] **Step 2: 新增 `tofu` job**（加在 `inspector-tests` 之後）

```yaml
  # Static checks only — tofu fmt + validate never touch live cloud resources.
  # `tofu init -backend=false` only downloads provider plugins from the
  # registry; it needs no cloud credentials (OCI's InstancePrincipal /
  # GCP's key are never exercised by `validate`).
  tofu:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up OpenTofu
        uses: opentofu/setup-opentofu@v1
        with:
          tofu_version: 1.12.6

      - name: tofu fmt -check + init + validate
        run: |
          failed=0
          for d in $(find . -type d -name tofu -not -path './.worktrees/*'); do
            echo "--- $d"
            (cd "$d" && tofu fmt -recursive -check) || failed=1
            (cd "$d" && tofu init -backend=false -input=false >/dev/null) || failed=1
            (cd "$d" && tofu validate) || failed=1
          done
          exit $failed
```

- [ ] **Step 3: 驗證 YAML 語法**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/repo-conventions.yml'))"`（無輸出即通過）

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/repo-conventions.yml
git commit -m "ci: add OpenTofu fmt/validate static checks"
```

---

### Task 3: `vps_gcp/` 骨架 + `vps_gcp/tofu/` scaffold

**Files:**
- Create: `vps_gcp/README.md`
- Create: `vps_gcp/tofu/README.md`
- Create: `vps_gcp/tofu/versions.tf`
- Create: `vps_gcp/tofu/provider.tf`
- Create: `vps_gcp/tofu/variables.tf`
- Create: `vps_gcp/tofu/.auto.tfvars.example`
- Modify: `README.md`（Host 列表表格加 `vps_gcp` 行）

**Interfaces:**
- Produces: `var.project_id`（string，必填）、`var.billing_account`（string，必填）——後續 Task 4/5/6 的 provider 與 budget 資源引用；`google_compute_network.main` 等資源名於 Task 4 起由後續任務定義。

- [ ] **Step 1: `vps_gcp/README.md`**（說明這台機器目前只納管 tofu 一層）

```markdown
# vps_gcp

GCP 免费层（free tier）e2-micro 实例。目前这台机器整机**不**纳入本仓库管理——这里只有 `tofu/` 一层，用于练 greenfield IaC 的完整生命周期（从零 apply → destroy → 再 apply 验证可重现）。

## 目前纳管范围

| 目录 | 是什么 | 约定见 |
|---|---|---|
| `tofu/` | OpenTofu root module：VPC / subnet / firewall / e2-micro 实例 / API 启用 / 预算告警 | [tofu/README.md](tofu/README.md) |

机器上跑什么、怎么部署、README 怎么写，另案处理；本目录暂时只此一层。
```

- [ ] **Step 2: `vps_gcp/tofu/README.md`**

```markdown
# vps_gcp/tofu — greenfield root module

练习 greenfield 的那半：完整生命周期，从零 apply → 改 → destroy → 再 apply 验证可重现。

## 免费层边界（敲死，别动）

| 项 | 值 | 为什么 |
|---|---|---|
| region / zone | `us-west1` / `us-west1-a` | e2-micro 仅 us-west1/us-central1/us-east1 免费 |
| machine_type | `e2-micro` | 写死字面值，不用变量，防手滑改成 e2-medium |
| boot disk | 30 GB `pd-standard` | 免费层 30 GB 标准永久磁盘总额 |
| egress | 1 GB/月（不含中国/澳洲） | 见 instance.tf 注释 |

## 认证

专设 service account + key JSON。角色收窄到 `roles/compute.networkAdmin`、`roles/compute.instanceAdmin.v1`、`roles/serviceusage.serviceUsageAdmin`。

- key 放仓库之外，经环境变量引用：`export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json`
- `.auto.tfvars`（gitignored）填 `project_id` 与 `billing_account` 两个必填项，见 `.auto.tfvars.example`。

`google_billing_budget` 的权限挂在**账单账户**上、不是项目上——需在账单账户层级授 `roles/billing.costsManager`。

## 验收标准

`tofu destroy` 之后 `tofu apply` 能完整重现，且重现后 `tofu plan` 输出 `No changes.`。

## 操作

```bash
cd vps_gcp/tofu
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
cp .auto.tfvars.example .auto.tfvars   # 填 project_id / billing_account
tofu init
tofu plan    # 验收：终态 No changes.
tofu apply
```
```

- [ ] **Step 3: `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.2.0"
    }
  }
}
```

- [ ] **Step 4: `provider.tf`**

```hcl
# Credentials come from the GOOGLE_APPLICATION_CREDENTIALS env var (a dedicated
# SA key living OUTSIDE this repo) — never inline a key here. The provider
# reads it implicitly; no `credentials` attribute is set on purpose.
provider "google" {
  project = var.project_id
  region  = "us-west1" # free-tier region, hardcoded (see README)
}
```

- [ ] **Step 5: `variables.tf`**

```hcl
variable "project_id" {
  description = "GCP project ID that owns the resources."
  type        = string
}

variable "billing_account" {
  description = "GCP billing account ID (format A1B2C3-D4E5F6-G7H8I9) for the budget; needs roles/billing.costsManager at the BILLING ACCOUNT level, not the project."
  type        = string
}
```

- [ ] **Step 6: `.auto.tfvars.example`**（提交的真身範本，無真實值；對齊倉庫既有 `.env.example` 慣例）

```hcl
project_id      = ""
billing_account = ""
```

- [ ] **Step 7: root `README.md` Host 列表加一行**

```markdown
| vps_gcp | GCP free-tier e2-micro（只纳管 `tofu/` 一层） | [vps_gcp/README.md](vps_gcp/README.md) |
```

- [ ] **Step 8: 靜態驗證（本 module 目前無 resource，純 schema 檢查）**

Run:
```bash
cd vps_gcp/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: 全綠，`Success! The configuration is valid.`

- [ ] **Step 9: 確認 `.auto.tfvars.example` 不在 gitignore 範圍**

Run: `git status --ignored --short vps_gcp/tofu/`（`example` 檔應顯示為待提交、非 ignored）

- [ ] **Step 10: Commit**

```bash
git add vps_gcp README.md
git commit -m "feat(vps_gcp): scaffold OpenTofu greenfield root module"
```

---

### Task 4: GCP 網路——VPC / subnet / firewall

**Files:**
- Create: `vps_gcp/tofu/network.tf`
- Create: `vps_gcp/tofu/firewall.tf`

**Interfaces:**
- Consumes: `var.project_id`（Task 3）；provider 已設定 region `us-west1`。
- Produces: `google_compute_network.main`、`google_compute_subnetwork.main`、`google_compute_firewall.ssh`——Task 5 的 `network_interface` 引用前兩者。

- [ ] **Step 1: `network.tf`**

```hcl
resource "google_compute_network" "main" {
  name                    = "vps-gcp-vpc"
  auto_create_subnetworks = false # custom-mode VPC: full control over the subnet
}

resource "google_compute_subnetwork" "main" {
  name          = "vps-gcp-subnet"
  network       = google_compute_network.main.id
  region        = "us-west1"
  ip_cidr_range = "10.0.0.0/24"
}
```

- [ ] **Step 2: `firewall.tf`**

```hcl
# Only SSH ingress. The instance itself carries the free-tier egress boundary.
resource "google_compute_firewall" "ssh" {
  name    = "allow-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}
```

- [ ] **Step 3: 靜態驗證**

Run:
```bash
cd vps_gcp/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add vps_gcp/tofu/network.tf vps_gcp/tofu/firewall.tf
git commit -m "feat(vps_gcp): declare VPC, subnet and SSH firewall rule"
```

---

### Task 5: GCP 運算——e2-micro 實例 + API 啟用

**Files:**
- Create: `vps_gcp/tofu/instance.tf`
- Create: `vps_gcp/tofu/services.tf`

**Interfaces:**
- Consumes: `google_compute_network.main.id` / `google_compute_subnetwork.main.id`（Task 4）；`var.project_id`（Task 3）。
- Produces: `google_compute_instance.vps`、`google_project_service.*`（後續 task 無依賴，budget 不依賴 instance）。

- [ ] **Step 1: `instance.tf`**

```hcl
# FREE-TIER BOUNDARY — every value below is a hardcoded literal on purpose,
# NOT a variable. Changing machine_type / region / disk size can produce real
# billing. See README "免费层边界" before touching anything here.
resource "google_compute_instance" "vps" {
  name         = "vps-gcp"
  machine_type = "e2-micro"   # free only in us-west1/us-central1/us-east1
  zone         = "us-west1-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30          # 30 GB is the free-tier standard-PD total
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      # ephemeral public IP — free tier allows 1 GB egress/month (excl. CN/AU)
    }
  }
}
```

- [ ] **Step 2: `services.tf`**

```hcl
# Declaratively track "which APIs are enabled". `disable_on_destroy = false`
# means the destroy/apply acceptance test does not tear down the APIs, only
# the resources on top of them.
resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "billingbudgets" {
  project            = var.project_id
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbilling" {
  project            = var.project_id
  service            = "cloudbilling.googleapis.com"
  disable_on_destroy = false
}
```

- [ ] **Step 3: 靜態驗證**

Run:
```bash
cd vps_gcp/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add vps_gcp/tofu/instance.tf vps_gcp/tofu/services.tf
git commit -m "feat(vps_gcp): declare free-tier e2-micro instance and API enablement"
```

---

### Task 6: GCP 成本護欄——`google_billing_budget`

**Files:**
- Create: `vps_gcp/tofu/budget.tf`

**Interfaces:**
- Consumes: `var.billing_account`（Task 3）；`var.project_id`（Task 3）。
- Produces: `google_billing_budget.free_tier`——Phase 1 收尾，無下游依賴。

- [ ] **Step 1: `budget.tf`**

```hcl
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
```

- [ ] **Step 2: 靜態驗證**

Run:
```bash
cd vps_gcp/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: `Success! The configuration is valid.`

> 若 provider 8.2.0 對 `budget_filter` 欄位名有變，`validate` 會在此步報出——依報錯訊息對齊欄位名，不改語意。這是唯一可能因 provider 版本而需微調的資源。

- [ ] **Step 3: Commit**

```bash
git add vps_gcp/tofu/budget.tf vps_gcp/tofu/.terraform.lock.hcl
git commit -m "feat(vps_gcp): add free-tier billing budget with alerts"
```

> 注意：此 step 首次 `tofu init` 會產生 `.terraform.lock.hcl`，務必連同提交（spec 要求 lock 檔進 git）。

---

### Task 7: GCP live 驗收——apply → destroy → apply → No changes

**Files:** 無（純操作）；若有 drift 微調，改對應 `.tf` 並追加至本任務。

**Interfaces:**
- Consumes: Task 3–6 定義的整套 GCP module。
- Produces: 線上 GCP 資源；Phase 1 驗收證據（`tofu plan` = `No changes.`）。

> **PREREQ 門檻**：前置條件 1（tofu 已裝）、3（SA key）、4（billing costsManager）已完成；`GOOGLE_APPLICATION_CREDENTIALS` 與 `.auto.tfvars` 已就緒。

- [ ] **Step 1: 確認憑證與 tfvars 就緒**

Run:
```bash
cd vps_gcp/tofu
test -n "$GOOGLE_APPLICATION_CREDENTIALS" && test -f "$GOOGLE_APPLICATION_CREDENTIALS" && echo "creds OK"
test -s .auto.tfvars && grep -qE '^(project_id|billing_account)\s*=\s*"[^"]+"' .auto.tfvars && echo "tfvars OK"
```
Expected: `creds OK` 與 `tfvars OK`。

- [ ] **Step 2: `tofu init`**

Run: `cd vps_gcp/tofu && tofu init`

- [ ] **Step 3: `tofu plan` 檢視資源清單**

Run: `cd vps_gcp/tofu && tofu plan`
Expected: plan 列出 VPC / subnet / firewall / instance / 3× `google_project_service` / budget，無錯誤。人工核對 instance 的 `machine_type = e2-micro`、`zone = us-west1-a`、`size = 30`。

- [ ] **Step 4: `tofu apply`**

Run: `cd vps_gcp/tofu && tofu apply`
Expected: 全部建立成功，`Apply complete!`。

- [ ] **Step 5: `tofu destroy`**（greenfield 的完整生命週期——這正是 spec 在 vps_oracle 上永不允許練的那一半）

Run: `cd vps_gcp/tofu && tofu destroy`
Expected: 資源全刪（API enable 因 `disable_on_destroy=false` 保留）。

- [ ] **Step 6: 再 `tofu apply` 驗證可重現**

Run: `cd vps_gcp/tofu && tofu apply`
Expected: 完整重現。

- [ ] **Step 7: 驗收 `tofu plan`**

Run: `cd vps_gcp/tofu && tofu plan`
Expected: **`No changes. Your infrastructure matches the configuration.`**

- [ ] **Step 8: （僅在有 drift 微調時）Commit**

```bash
git add vps_gcp/tofu
git commit -m "fix(vps_gcp): align <resource> to converge on No changes"
```

---

### Task 8: `vps_oracle/tofu/` scaffold（brownfield，先立骨架）

**Files:**
- Create: `vps_oracle/tofu/README.md`
- Create: `vps_oracle/tofu/versions.tf`
- Create: `vps_oracle/tofu/provider.tf`
- Create: `vps_oracle/tofu/variables.tf`
- Create: `vps_oracle/tofu/.auto.tfvars.example`
- Modify: `vps_oracle/README.md`（「目錄結構」表格加 `tofu/` 行）
- Modify: `README.md`（「約定」一節「另外兩份規則」→「另外三份規則」）

**Interfaces:**
- Produces: `var.region`、`var.tenancy_ocid`、`var.compartment_id` 與五個 OCID 變數（Task 9 探查後於 `.auto.tfvars` 填入）；provider 走 Instance Principal。後續 Task 10 的 `import {}` 區塊與資源區塊引用這些變數。

- [ ] **Step 1: `vps_oracle/tofu/README.md`**

```markdown
# vps_oracle/tofu — brownfield root module

练习 brownfield 的那半：`import` 已存在且被 console 手改过的资源、驯服 drift、`ignore_changes`。这台机器永远不能重建，只能练这半。

## 红线

> **禁止在此目录执行 `tofu destroy`。**

IAM 硬墙已让 `destroy` 打不到运算实例与 boot volume（policy 只授 `manage virtual-network-family`），但红线仍要写明——纵深防御。

## 验证标准

`tofu plan` 输出 `No changes.`

这一步会比预期久：OCI API 会回一堆 console 从未显示的默认字段，逐个对齐、或判断哪些该进 `ignore_changes`，就是这节的功课。

## 目录说明

| 文件 | 职责 |
|---|---|
| `versions.tf` | required_version / required_providers（钉死版本） |
| `provider.tf` | `auth = "InstancePrincipal"` |
| `variables.tf` | region / tenancy_ocid / compartment_id + 五个资源 OCID |
| `network.tf` | VCN / subnet / IGW / route table / security list |
| `imports.tf` | `import {}` 区块（id 引用变量，实测 OCID 放 `.auto.tfvars`） |

OCID 填在 gitignored 的 `.auto.tfvars`（见 `.auto.tfvars.example`），不进 git。

若探查发现这台用的是**默认**路由表/安全列表（display name 为 "Default Route Table/Security List for <vcn>"），resource 型别要用 `oci_core_default_route_table` / `oci_core_default_security_list`（见 Task 10 的分支说明）。
```

- [ ] **Step 2: `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "9.0.0"
    }
  }
}
```

- [ ] **Step 3: `provider.tf`**

```hcl
# InstancePrincipal — this very instance is the identity. Zero long-lived
# credentials on disk, auto-rotated by OCI. Requires a Dynamic Group matching
# this instance's OCID + a policy granting `manage virtual-network-family`
# ONLY (the IAM hard wall — see spec "IAM 硬墙"). The `region` comes from
# .auto.tfvars; the tenancy home region is discoverable in the console.
provider "oci" {
  auth   = "InstancePrincipal"
  region = var.region
}
```

- [ ] **Step 4: `variables.tf`**

```hcl
variable "region" {
  description = "Tenancy home region (e.g. ap-tokyo-1); console tenant page."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (console: Profile → Tenancy)."
  type        = string
}

variable "compartment_id" {
  description = "Compartment holding the resources; usually the root compartment = tenancy_ocid."
  type        = string
}

# Discovered OCIDs — filled during the probe (Task 9), stored gitignored.
variable "vcn_ocid"               { type = string }
variable "subnet_ocid"            { type = string }
variable "internet_gateway_ocid"  { type = string }
variable "route_table_ocid"       { type = string }
variable "security_list_ocid"     { type = string }
```

- [ ] **Step 5: `.auto.tfvars.example`**

```hcl
region                = ""
tenancy_ocid          = ""
compartment_id        = ""
vcn_ocid              = ""
subnet_ocid           = ""
internet_gateway_ocid = ""
route_table_ocid      = ""
security_list_ocid    = ""
```

- [ ] **Step 6: 更新 `vps_oracle/README.md` 目錄結構表格**（`host-firewall/` 行下加）

```markdown
| `tofu/` | OpenTofu brownfield 收編：VCN / subnet / IGW / route table / security list（遞回納管上游那層 OCI 網路資源） | [tofu/README.md](tofu/README.md) |
```

- [ ] **Step 7: 更新 root `README.md` 規則指引**（「另外兩份規則」所在段）

```markdown
另外三份规则：k3s/ArgoCD 的改动纪律见 [`.claude/rules/k3s-gitops.md`](.claude/rules/k3s-gitops.md)，OpenTofu 的收编/免费层/版本红线见 [`.claude/rules/tofu-conventions.md`](.claude/rules/tofu-conventions.md)，文档该写进哪一层见 [`.claude/rules/docs-layout.md`](.claude/rules/docs-layout.md)。
```

- [ ] **Step 8: 靜態驗證（此時無 resource、無 import，僅 schema）**

Run:
```bash
cd vps_oracle/tofu && tofu fmt -recursive -check && tofu init -backend=false -input=false && tofu validate
```
Expected: `Success! The configuration is valid.`

> 若本機未裝 tofu，可改用 CI 驗證（Task 2 的 job 已涵蓋此 module）。`validate` 不觸發 OCI API，不需憑證。

- [ ] **Step 9: Commit**

```bash
git add vps_oracle/tofu vps_oracle/README.md README.md
git commit -m "feat(vps_oracle): scaffold OpenTofu brownfield root module"
```

---

### Task 9: OCI 探查——與線上對齊的 factsheet

**Files:**
- Create: `vps_oracle/tofu/probe.tf`（**一次性，探查後刪除，不提交**）

**Interfaces:**
- Consumes: `var.region` / `var.compartment_id`（Task 8 變數，`.auto.tfvars` 已填）。
- Produces: 一份 factsheet——五個 OCID（VCN/subnet/IGW/route table/security list）、每個資源的 display name、以及「這台用的是預設還是自建 route table／security list」的判定。這份 factsheet 是 Task 10 的輸入。

> **PREREQ 門檻**：前置條件 1（tofu 裝好）、2（Dynamic Group + policy 建好）。

- [ ] **Step 1: 確認 InstancePrincipal 至少「能看見」網路資源**

Run:
```bash
cd vps_oracle/tofu
test -s .auto.tfvars && echo "tfvars ready"
```

- [ ] **Step 2: 寫一次性 `probe.tf`**（data source 唯讀探查，`tofu apply` 只讀不改）

```hcl
# One-shot probe — delete this file after extracting the factsheet.
data "oci_identity_tenancy" "t" {
  tenancy_id = var.tenancy_ocid
}

data "oci_core_vcns" "all"   { compartment_id = var.compartment_id }
data "oci_core_subnets" "all" { compartment_id = var.compartment_id }
data "oci_core_internet_gateways" "all" { compartment_id = var.compartment_id }
data "oci_core_route_tables" "all" { compartment_id = var.compartment_id }
data "oci_core_security_lists" "all" { compartment_id = var.compartment_id }

output "factsheet" {
  value = {
    vcns     = data.oci_core_vcns.all.virtual_networks
    subnets  = data.oci_core_subnets.all.subnets
    igws     = data.oci_core_internet_gateways.all.gateways
    routes   = data.oci_core_route_tables.all.route_tables
    sec_lists = data.oci_core_security_lists.all.security_lists
  }
}
```

- [ ] **Step 3: 跑探查**

Run:
```bash
cd vps_oracle/tofu && tofu init && tofu apply -auto-approve && tofu output factsheet
```
Expected: 輸出五類資源的 `id`、`display_name`、`cidr_block(s)`、以及 route table / security list 的 `route_rules`、`ingress_security_rules`。

- [ ] **Step 4: 判定資源型別**（關鍵決策）

在 factsheet 中找 route table 與 security list 的 `display_name`：

- 若為 **"Default Route Table for <vcn>"** → 這台的 route table 是**預設**，Task 10 用 `oci_core_default_route_table`，其 `manage_default_resource_id = <vcn_ocid>`。
- 若為 **"Default Security List for <vcn>"** → 用 `oci_core_default_security_list`。
- 否則為自建，用普通 `oci_core_route_table` / `oci_core_security_list`。

記錄判定結果與五個 OCID 進 factsheet（寫在 Task 10 的進行說明或本地筆記，不進 git）。

- [ ] **Step 5: 刪除 `probe.tf`**

Run: `rm vps_oracle/tofu/probe.tf && cd vps_oracle/tofu && tofu apply -auto-approve`（第二個 apply 移除 output，為 Task 10 的清淨 base 做準備）

- [ ] **Step 6: （無提交）**——`probe.tf` 是一次性副作用，不進版本控制。本任務無 commit。

---

### Task 10: OCI 收編——network.tf + imports.tf，收斂到 No changes

**Files:**
- Create: `vps_oracle/tofu/network.tf`
- Create: `vps_oracle/tofu/imports.tf`

**Interfaces:**
- Consumes: Task 9 的 factsheet（五個 OCID + 資源型別判定）；Task 8 的 OCID 變數（`.auto.tfvars` 已填實測值）。
- Produces: 五個被 `import` 納管的資源；`tofu plan` = `No changes.` 的驗收證據。

> **PREREQ 門檻**：Task 9 已完成；五個 OCID 已填進 `.auto.tfvars`。

brownfield 的本質是「align 到 OCI 實際持有的值」。下面 `network.tf` 給的是**普通的資源型別 + 代表值**；每一處 `<probed>` 都用 Task 9 factsheet 的實際值替換，**不發明值**。若 Task 9 判定為預設型別，先跳到「Step 5 分支」。

- [ ] **Step 1: 寫 `imports.tf`**（id 引用變數，OCID 留在 gitignored tfvars，進 git 的只有結構）

```hcl
# Declarative import — the `id`s come from .auto.tfvars (gitignored), so no
# OCID literal enters git. Converge to `No changes.` before considering this
# "done": the resource bodies in network.tf must match what OCI actually holds.
import {
  to = oci_core_vcn.main
  id = var.vcn_ocid
}
import {
  to = oci_core_subnet.public
  id = var.subnet_ocid
}
import {
  to = oci_core_internet_gateway.igw
  id = var.internet_gateway_ocid
}
import {
  to = oci_core_route_table.rt
  id = var.route_table_ocid
}
import {
  to = oci_core_security_list.sl
  id = var.security_list_ocid
}
```

- [ ] **Step 2: 寫 `network.tf` 資源骨架（普通型別路徑）**

```hcl
resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = ["<probed>"]   # e.g. ["10.0.0.0/16"]
  display_name   = "<probed>"
}

resource "oci_core_subnet" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = "<probed>"
  display_name   = "<probed>"
  route_table_id = oci_core_route_table.rt.id
  security_list_ids = [oci_core_security_list.sl.id]
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "<probed>"
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "<probed>"
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "sl" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "<probed>"
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
  # ingress rules copied VERBATIM from the fact sheet (22/80/443 for this host),
  # not invented here.
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options { min = 22; max = 22 }
  }
  # ...其余 ingress 规则一律按 factsheet 原样补齐
}
```

- [ ] **Step 3: 跑 import + 收斂迴圈**（本任務的核心功課，會比預期久）

Run 迴圈，直到 `No changes.`：
```bash
cd vps_oracle/tofu
tofu init
tofu plan     # 首次：列出 import（新增）與欄位 diff
tofu apply    # 完成 import + 寫入 state
tofu plan     # 此後每一次都是純 drift 比對
```
每輪 `tofu plan` 報出的 diff，逐欄判斷：
- 是 OCI 實際持有、但我們沒寫 → 補進 `network.tf` 對應欄位；
- 是 tofu 無法預知／無意管理的預設欄位 → 加 `ignore_changes`。

- [ ] **Step 4: `ignore_changes` 的正確姿勢**（在對應 resource 內追加，並把原因寫進 `vps_oracle/tofu/README.md`）

```hcl
resource "oci_core_vcn" "main" {
  # ...
  lifecycle {
    ignore_changes = [
      # <field>: OCI returns/updates this outside Terraform's view; accepting
      # it quiets the diff without claiming to manage it. Reason recorded in
      # the README (spec: "对特定字段 ignore_changes 并在 README 记录原因").
    ]
  }
}
```

- [ ] **Step 5: 分支——若 Task 9 判定為預設型別**

把 `network.tf` 中 `oci_core_route_table.rt` 換成：

```hcl
resource "oci_core_default_route_table" "rt" {
  manage_default_resource_id = var.vcn_ocid
  # 其余 route 属性按 factsheet 对齐（默认 RT 由 VCN 自动随建）
}
```

`oci_core_security_list.sl` 同理換成 `oci_core_default_security_list`（`manage_default_resource_id = var.vcn_ocid`）。subnet 的 `route_table_id` / `security_list_ids` 仍指向這兩個 resource 的同一語意。`imports.tf` 的 `to =` 也同步改成 default 型別。**收斂迴圈（Step 3）不變。**

- [ ] **Step 6: 驗收**

Run: `cd vps_oracle/tofu && tofu plan`
Expected: **`No changes. Your infrastructure matches the configuration.`**

- [ ] **Step 7: Commit**

```bash
git add vps_oracle/tofu/network.tf vps_oracle/tofu/imports.tf vps_oracle/tofu/.terraform.lock.hcl vps_oracle/tofu/README.md
git commit -m "feat(vps_oracle): import OCI network resources into tofu"
```

---

### Task 11: OCI IAM 硬牆負面驗證（唯讀）＋清理

**Files:**
- Create: `vps_oracle/tofu/wall-check.tf`（**一次性，驗證後刪除，不提交**）

**Interfaces:**
- Consumes: Task 10 的 module；`var.compartment_id`。
- Produces: 一條安全的**負面驗證**證據——tofu 的身分連「看見」本機運算實例都做不到（404），遑論刪除。做完即移除，不留痕跡進 git。

> **PREREQ 門檻**：Task 10 已完成。

- [ ] **Step 1: 寫一次性 `wall-check.tf`**

```hcl
# Negative proof of the IAM hard wall: a `data` source pointing at the live
# instance. The policy grants only `manage virtual-network-family`, so OCI
# returns 404/403 for compute resources — tofu cannot even SEE the instance,
# let alone destroy it. Purely read-only. Delete after verifying.
data "oci_core_instance" "self" {
  instance_id = var.instance_ocid # the OCID of THIS very machine
}
```

說明：`var.instance_ocid` 需先加到 `variables.tf` 並在 `.auto.tfvars` 填本機 OCID（console 或 `curl http://169.254.169.254/opc/v2/instance/id` 取得）。此變數**只在本任務的生命週期內存在**，驗證後連同 `wall-check.tf` 一起移除。

- [ ] **Step 2: 跑 plan，預期「因權限不足失敗」**

Run: `cd vps_oracle/tofu && tofu plan`
Expected: **失敗**——OCI 對未授權的 compute 資源回 404/403（provider 錯誤含 `NotAuthorizedOrNotFound` 或 `404`）。**這是成功的訊號，不是 bug。**

- [ ] **Step 3: 移除一次性檔案與變數**

Run:
```bash
cd vps_oracle/tofu
git checkout -- variables.tf 2>/dev/null || true   # 若不是 git 追蹤的內容則手動刪除 instance_ocid 變數
rm wall-check.tf
# 從 .auto.tfvars 移除 instance_ocid 行
```
再跑 `tofu plan` 確認恢復 `No changes.`（回到 Task 10 終態）。

- [ ] **Step 4: 確認工作樹乾淨**

Run: `git status --short vps_oracle/tofu/`（預期無殘留：`wall-check.tf` 已刪、`variables.tf` 無 `instance_ocid`、無 `probe.tf`）

- [ ] **Step 5: （無提交）**——負面驗證是一次性事實，不進版本控制。

---

## 收尾自檢（合併前）

- [ ] `git status` 乾淨，無 `.tfstate`、無 `.auto.tfvars`（含實值）、無 `probe.tf` / `wall-check.tf` 殘留。
- [ ] `.terraform.lock.hcl` 已提交（兩個 module 各一份）。
- [ ] CI `tofu` job 能在乾淨 checkout 上通過（`fmt -check` + `init` + `validate`）。
- [ ] `vps_oracle/tofu/` 紅線（禁 `destroy`）已寫進 `tofu-conventions.md` 與 `vps_oracle/tofu/README.md` 兩處。
- [ ] spec 未承諾的 Phase 3（共享資源池 module、redis ACL provider）**沒有**被誤放進本計畫。

## 未納入本計畫（spec 明確 YAGNI / 後續練習）

| 不做 | 留作 |
|---|---|
| 遠端 state backend | 後續練習（遷移本身是一課） |
| GCP impersonation（ADC + SA impersonation 取代 key） | 後續練習（第一階段先 key 跑順） |
| 共享資源池 per-service module（minio/postgres） | Phase 3，未承諾 |
| redis ACL 自動化 | 無 provider，繼續 `gen-users-acl.sh` |
| NPM / ClouDNS / docker / k8s 收編 | 已有 owner，疊上去等於一個資源兩個 owner |
| OCI 運算實例 / boot volume | IAM 硬牆 + 爆炸半徑過大 |
# FinOps — cost management, budgets, and billing alerts
# These values are safe to commit — they contain no secrets.

aws_region     = "us-east-1"
aws_account_id = "470439679607"
environment  = "dev"
cost_center  = "ENG-001"
team         = "engineering"
owner        = "engineering"

# Email that receives all budget alerts, anomaly alerts, and billing alarms.
# Change this to your email before running spinup.sh.
budget_alert_email = "oseweka1@gmail.com"

# Monthly budget limits (USD)
monthly_budget_dev  = 200
monthly_budget_prod = 1000

# Alert fires at this % of the monthly budget (80% = alert before you hit the limit)
budget_alert_threshold_percent = 80

# CloudWatch billing alarm fires when account EstimatedCharges exceeds this (USD)
billing_alarm_threshold_usd = 200

# Set to true only AFTER first apply — AWS requires tag keys to exist on resources
# before they can be activated as cost allocation tags in Cost Explorer.
# Activating on first apply throws: "Tag keys not found"
enable_cost_allocation_tags = false

# Set to true to enable Cost Anomaly Detection (alerts when a service spikes > $50).
# AWS has an account-level limit on dimensional monitors — leave false if you hit the limit.
enable_anomaly_detection = false

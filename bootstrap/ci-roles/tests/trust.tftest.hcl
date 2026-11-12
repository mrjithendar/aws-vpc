provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}
run "all_three" {
  command = plan
  variables {
    enable_gitlab     = true
    jenkins_role_arns = ["arn:aws:iam::123456789012:role/jenkins-agent"]
  }
  assert {
    condition     = length(jsondecode(data.aws_iam_policy_document.plan_trust.json).Statement) == 3
    error_message = "plan trust should have GitHub, GitLab, Jenkins"
  }
  assert {
    condition     = strcontains(data.aws_iam_policy_document.apply_trust.json, "project_path:mrjithendar/aws-vpc:ref_type:branch:ref:master") && strcontains(data.aws_iam_policy_document.apply_trust.json, "repo:mrjithendar/aws-vpc:environment:prod")
    error_message = "apply trust subjects"
  }
}
run "none_rejected" {
  command = plan
  variables { enable_github = false }
  expect_failures = [aws_iam_role.plan]
}

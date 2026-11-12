// Plan on every run; apply only after a human approves the exact saved plan.
// Credentials: the agent's instance profile (or IRSA/pod identity) is used, and
// Terraform optionally assumes DEPLOY_ROLE_ARN. No static access keys.
pipeline {
    agent { label 'terraform' }

    options {
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    parameters {
        choice(name: 'ENV', choices: ['dev', 'prod'], description: 'Environment (selects backend/<env>.hcl and vars/<env>.tfvars)')
        booleanParam(name: 'APPLY', defaultValue: false, description: 'Apply after plan (requires approval)')
        string(name: 'DEPLOY_ROLE_ARN', defaultValue: '', description: 'Optional IAM role for Terraform to assume')
    }

    environment {
        TF_IN_AUTOMATION = 'true'
        TF_INPUT         = '0'
        AWS_REGION       = 'us-east-1'
    }

    stages {
        stage('Init') {
            steps {
                sh 'terraform version'
                sh "terraform init -reconfigure -backend-config=backend/${params.ENV}.hcl"
            }
        }

        stage('Static checks') {
            steps {
                sh 'terraform fmt -check -recursive'
                sh 'terraform validate'
                sh 'tflint --init && tflint --format compact'
                sh 'checkov -d . --framework terraform --compact --quiet'
            }
        }

        stage('Plan') {
            steps {
                sh """
                    # Only pass the role when one was given; empty would be an invalid ARN.
                    if [ -n "\$DEPLOY_ROLE_ARN" ]; then export TF_VAR_assume_role_arn="\$DEPLOY_ROLE_ARN"; fi
                    terraform plan -var-file=vars/${params.ENV}.tfvars -out=planfile -lock-timeout=5m
                    terraform show -no-color planfile > plan.txt
                """
                archiveArtifacts artifacts: 'plan.txt', fingerprint: true
            }
        }

        stage('Approve') {
            when { expression { params.APPLY } }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Apply VPC plan to ${params.ENV}? Review plan.txt first.", ok: 'Apply'
                }
            }
        }

        stage('Apply') {
            when { expression { params.APPLY } }
            steps {
                sh """
                    # Only pass the role when one was given; empty would be an invalid ARN.
                    if [ -n "\$DEPLOY_ROLE_ARN" ]; then export TF_VAR_assume_role_arn="\$DEPLOY_ROLE_ARN"; fi
                    terraform apply -lock-timeout=5m planfile
                """
            }
        }
    }

    post {
        always {
            sh 'rm -f planfile'
        }
    }
}

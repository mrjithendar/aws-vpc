// Jenkins pipeline for aws-vpc (use as a Multibranch Pipeline job).
//
//   PR / feature branch      -> checks + plan dev & prod (plan only)
//   master (push)            -> checks + plan dev -> apply dev -> plan prod -> approval -> apply prod
//                               ...only when AWS_VPC_DEPLOYER == 'jenkins'. Otherwise master builds are
//                               plan-only, so Jenkins never races GitHub Actions / GitLab CI for the state.
//   nightly on master        -> drift detection: plan both envs, build UNSTABLE if anything drifted
//   Build with Parameters    -> plan one env; APPLY=true applies it (master only; prod needs approval)
//
// Agent requirements: label 'docker' with Docker installed. All tools run in pinned containers, so
// nothing else is installed on the agent. AWS credentials come from the agent's instance profile
// (on EC2 set the IMDSv2 hop limit to 2 so containers can reach it), optionally assuming:
//   AWS_VPC_PLAN_ROLE_ARN   read-only + state lock role, used for plans
//   AWS_VPC_APPLY_ROLE_ARN  deploy role, used for applies
// Set these, plus AWS_VPC_DEPLOYER and AWS_VPC_PROD_APPROVERS, as global or folder environment
// variables. The roles come from bootstrap/ci-roles (var.jenkins_role_arns).

pipeline {
    agent none

    options {
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '50', artifactNumToKeepStr: '20'))
        durabilityHint('PERFORMANCE_OPTIMIZED')
    }

    triggers {
        // Nightly drift check on master only.
        cron(env.BRANCH_NAME == 'master' ? 'H 2 * * *' : '')
    }

    parameters {
        choice(name: 'ENV', choices: ['dev', 'prod'], description: 'Environment for a manual run')
        booleanParam(name: 'APPLY', defaultValue: false, description: 'Apply after plan (master only; prod requires approval)')
    }

    environment {
        // Pin tool images; bump deliberately. Keep the Terraform version in step with the other CI files.
        TF_IMAGE      = 'hashicorp/terraform:1.13.3'
        TFLINT_IMAGE  = 'ghcr.io/terraform-linters/tflint:v0.58.0'
        CHECKOV_IMAGE = 'bridgecrew/checkov:latest'

        TF_IN_AUTOMATION = 'true'
        TF_INPUT         = '0'
        AWS_REGION       = 'us-east-1'
    }

    stages {
        stage('Checks') {
            parallel {
                stage('fmt / validate / test') {
                    agent { label 'docker' }
                    options { timeout(time: 15, unit: 'MINUTES') }
                    steps {
                        script {
                            inContainer(env.TF_IMAGE) {
                                sh '''
                                    mkdir -p "$TF_PLUGIN_CACHE_DIR"
                                    terraform fmt -check -recursive -diff
                                    terraform init -backend=false -input=false
                                    terraform validate -no-color
                                    terraform test -no-color
                                '''
                            }
                        }
                    }
                }
                stage('tflint') {
                    agent { label 'docker' }
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        script {
                            inContainer(env.TFLINT_IMAGE) {
                                sh 'tflint --init && tflint --format compact'
                            }
                        }
                    }
                }
                stage('checkov') {
                    agent { label 'docker' }
                    options { timeout(time: 10, unit: 'MINUTES') }
                    steps {
                        script {
                            inContainer(env.CHECKOV_IMAGE) {
                                sh 'checkov -d . --framework terraform --skip-path bootstrap --compact --quiet --output cli --output junitxml --output-file-path console,.'
                            }
                        }
                    }
                    post {
                        always { junit allowEmptyResults: true, testResults: 'results_junitxml.xml' }
                    }
                }
            }
        }

        stage('Plan dev') {
            when { beforeAgent true; expression { shouldPlan('dev') } }
            agent { label 'docker' }
            options { timeout(time: 30, unit: 'MINUTES') }
            steps {
                script { env.DEV_CHANGES = planEnv('dev') ? 'true' : 'false' }
            }
        }

        stage('Apply dev') {
            when { beforeAgent true; expression { shouldApply('dev') && env.DEV_CHANGES == 'true' } }
            agent { label 'docker' }
            options { timeout(time: 45, unit: 'MINUTES') }
            steps {
                script { applyEnv('dev') }
            }
        }

        stage('Plan prod') {
            when { beforeAgent true; expression { shouldPlan('prod') } }
            agent { label 'docker' }
            options { timeout(time: 30, unit: 'MINUTES') }
            steps {
                script { env.PROD_CHANGES = planEnv('prod') ? 'true' : 'false' }
            }
        }

        // Runs without an agent, so waiting for approval doesn't hold an executor.
        stage('Approve prod') {
            when { expression { shouldApply('prod') && env.PROD_CHANGES == 'true' } }
            steps {
                timeout(time: 24, unit: 'HOURS') {
                    input(
                        message: "Apply the prod VPC plan from build #${env.BUILD_NUMBER}? Review plan-prod.txt in the build artifacts first.",
                        ok: 'Apply to prod',
                        submitter: env.AWS_VPC_PROD_APPROVERS   // null = any user with build permission
                    )
                }
            }
        }

        stage('Apply prod') {
            when { beforeAgent true; expression { shouldApply('prod') && env.PROD_CHANGES == 'true' } }
            agent { label 'docker' }
            options { timeout(time: 45, unit: 'MINUTES') }
            steps {
                script { applyEnv('prod') }
            }
        }
    }

    post {
        unstable {
            echo 'Build UNSTABLE: drift detected. See the plan-*.txt artifacts.'
        }
        failure {
            echo "aws-vpc pipeline failed on ${env.BRANCH_NAME}: ${env.BUILD_URL}"
        }
    }
}

//----------------------------------------------------------------------------
// Helpers
//----------------------------------------------------------------------------

// Run a block inside a tool container, as the Jenkins user, with a writable HOME and a
// per-workspace provider cache (WORKSPACE is only known once a stage has an agent).
def inContainer(String image, Closure body) {
    withEnv(["TF_PLUGIN_CACHE_DIR=${env.WORKSPACE}/.tf-plugin-cache"]) {
        docker.image(image).inside("--entrypoint='' -e HOME=/tmp") {
            body()
        }
    }
}

def isDriftRun() {
    return !currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause').isEmpty()
}

def isManualRun() {
    return !currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause').isEmpty()
}

def isMaster() {
    return env.BRANCH_NAME == 'master' && env.CHANGE_ID == null
}

def shouldPlan(String e) {
    return isManualRun() ? params.ENV == e : true
}

def shouldApply(String e) {
    if (isDriftRun() || !isMaster()) {
        return false
    }
    if (isManualRun()) {
        return params.APPLY && params.ENV == e
    }
    // Automatic applies on master only when Jenkins is the designated deployer.
    return (env.AWS_VPC_DEPLOYER ?: 'github') == 'jenkins'
}

def roleArn(String kind) {
    def arn = (kind == 'apply') ? env.AWS_VPC_APPLY_ROLE_ARN : env.AWS_VPC_PLAN_ROLE_ARN
    return arn?.trim() ? arn.trim() : null
}

// Backend args: per-env backend file, plus an assume_role block when a role is configured.
def backendArgs(String e, String kind) {
    def args = "-backend-config=backend/${e}.hcl"
    def role = roleArn(kind)
    if (role) {
        writeFile file: 'backend-role.hcl', text: "assume_role = {\n  role_arn     = \"${role}\"\n  session_name = \"jenkins-aws-vpc-${kind}-${e}\"\n}\n"
        args += ' -backend-config=backend-role.hcl'
    }
    return args
}

// Provider assumes the same role via var.assume_role_arn.
def providerRoleEnv(String kind) {
    def role = roleArn(kind)
    return role ? "export TF_VAR_assume_role_arn='${role}'" : 'unset TF_VAR_assume_role_arn'
}

// Plan one environment. Archives plan-<env>.txt, stashes the plan and lock file for the
// apply stage, and returns true if there are changes.
def planEnv(String e) {
    def changed = false
    inContainer(env.TF_IMAGE) {
        sh "mkdir -p \"\$TF_PLUGIN_CACHE_DIR\" && terraform init -reconfigure -input=false ${backendArgs(e, 'plan')}"

        def ec = sh(returnStatus: true, script: """
            ${providerRoleEnv('plan')}
            terraform plan -input=false -no-color -lock-timeout=5m \\
              -var-file=vars/${e}.tfvars -out=planfile -detailed-exitcode > plan-${e}.log 2>&1
        """)
        sh "cat plan-${e}.log"
        if (ec == 1) {
            error("terraform plan failed for ${e}")
        }
        changed = (ec == 2)

        sh "terraform show -no-color planfile > plan-${e}.txt"
        archiveArtifacts artifacts: "plan-${e}.txt", fingerprint: true
        stash name: "plan-${e}", includes: 'planfile,.terraform.lock.hcl'

        def summary = sh(returnStdout: true, script: "grep -E '^(Plan:|No changes\\.)' plan-${e}.log | tail -1 || true").trim()
        currentBuild.description = (currentBuild.description ?: '') + "${e}: ${summary ?: 'see log'}<br/>"
    }

    if (changed && isDriftRun()) {
        unstable("Drift detected in ${e}: live infrastructure differs from master")
    }
    return changed
}

// Apply exactly the stashed plan. Terraform refuses if state changed since the plan.
def applyEnv(String e) {
    unstash "plan-${e}"
    inContainer(env.TF_IMAGE) {
        sh "mkdir -p \"\$TF_PLUGIN_CACHE_DIR\" && terraform init -reconfigure -input=false ${backendArgs(e, 'apply')}"
        sh """
            ${providerRoleEnv('apply')}
            terraform apply -input=false -no-color -lock-timeout=5m planfile
            terraform output -no-color > outputs-${e}.txt
        """
        archiveArtifacts artifacts: "outputs-${e}.txt"
        sh 'rm -f planfile backend-role.hcl'
    }
}

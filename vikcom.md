Delete these 2 files
.github/workflows/reusable-workflow-plan.yaml
.github/workflows/reusable-workflow-apply.yaml
1. .github/workflows/deploy-bicep-infrastructure.yaml (replace everything)

# Deploy AI Code Checker (AICC) infrastructure through tto-sdt-infra template specs.
# Single asset (aicc), so plan, approval and apply live in this one workflow (same layout as tax-ai-library-infra).
# tto-sdt-infra actions, workflows and template specs are pinned to the "aicc" ref/version.
# Non-prod: subscription US-AZSUB-AME-TAX-VIHAANAI-NPD, secret NPD_VIHAAN_AZURE_CREDENTIALS
# (service principal JSON whose subscriptionId must match that subscription).
# Also required: secret APP_CI_GITHUB_PEM and variable APP_CI_GITHUB_ID (organization level),
# GitHub environments dev and approve_dev.

name: Deploy AICC Infrastructure
run-name: Deploy AICC infrastructure to ${{ inputs.environment }}

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Environment to deploy to'
        required: true
        default: 'dev'
        type: choice
        options:
          - dev

permissions:
  contents: read

concurrency:
  group: aicc-infra-deploy-${{ github.ref }}-${{ inputs.environment }}
  cancel-in-progress: false

jobs:
  # Analyze which runner to use: AKS self-hosted runner tag when deployed, otherwise ubuntu-latest
  init:
    name: Init
    uses: Deloitte-US-Tax/tto-sdt-infra/.github/workflows/reusable-workflow-analyze-runners.yml@aicc
    with:
      environment: ${{ inputs.environment }}
    secrets: inherit

  plan:
    name: Plan-Validate-${{ inputs.environment }}
    needs: init
    runs-on: ${{ needs.init.outputs.runner }}
    timeout-minutes: 30
    environment: ${{ inputs.environment }}
    env:
      AZURE_CREDENTIALS: ${{ secrets.NPD_VIHAAN_AZURE_CREDENTIALS }}
    outputs:
      resource_group_aicc: ${{ steps.generate-and-plan-aicc.outputs.resource_group }}
    steps:
      - name: Get GitHub App token for reusable workflows
        id: app-token-sdt-repo
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.APP_CI_GITHUB_ID }}
          private-key: ${{ secrets.APP_CI_GITHUB_PEM }}
          owner: Deloitte-US-Tax
          repositories: tto-sdt-infra

      - name: Checkout Project ${{ github.repository }}
        uses: actions/checkout@v6
        with:
          repository: ${{ github.repository }}
          path: "project"
          ref: "${{ github.ref_name }}"

      - name: Checkout shared infrastructure
        uses: actions/checkout@v6
        with:
          repository: Deloitte-US-Tax/tto-sdt-infra
          ref: aicc
          path: sdt-infra
          token: ${{ steps.app-token-sdt-repo.outputs.token }}

      - name: Resolve environment Azure credentials
        shell: bash
        run: |
          set -euo pipefail
          if [ -z "${AZURE_CREDENTIALS:-}" ]; then
            echo "::error::Azure credentials secret not found. Expected NPD_VIHAAN_AZURE_CREDENTIALS."
            exit 1
          fi

          echo "✅ Credentials resolved successfully"

      - name: Login to Azure with credentials JSON
        uses: azure/login@v3
        with:
          creds: ${{ env.AZURE_CREDENTIALS }}

      - name: Export Azure credential fields
        uses: Deloitte-US-Tax/tto-sdt-infra/.github/actions/deployment/common/parse-azure-credentials-env@aicc
        with:
          azure_credentials: ${{ env.AZURE_CREDENTIALS }}

      - name: Plan and Validate Bicep AICC
        id: generate-and-plan-aicc
        uses: Deloitte-US-Tax/tto-sdt-infra/.github/actions/deployment/bicep-plan@aicc
        with:
          asset: aicc
          environment: ${{ inputs.environment }}
          azure_subscription_id: ${{ env.AZURE_SUBSCRIPTION_ID }}
          replace_variables: '${{ toJSON(vars) }},${{ toJSON(secrets) }}'
          sdt_infra_dir: ${{ github.workspace }}/sdt-infra
          use_iac_storage: false

  approve:
    name: Approve
    needs:
      - init
      - plan
    uses: Deloitte-US-Tax/tto-sdt-infra/.github/workflows/reusable-workflow-review.yml@aicc
    with:
      environment: ${{ inputs.environment }}
      runner: ${{ needs.init.outputs.runner }}

  apply:
    name: Apply-${{ inputs.environment }}
    needs:
      - init
      - plan
      - approve
    runs-on: ${{ needs.init.outputs.runner }}
    timeout-minutes: 60
    environment: ${{ inputs.environment }}
    env:
      AZURE_CREDENTIALS: ${{ secrets.NPD_VIHAAN_AZURE_CREDENTIALS }}
    outputs:
      outputs_present_aicc: ${{ steps.apply-aicc.outputs.outputs_present }}
    steps:
      - name: Get GitHub App token for reusable workflows
        id: app-token-sdt-repo
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.APP_CI_GITHUB_ID }}
          private-key: ${{ secrets.APP_CI_GITHUB_PEM }}
          owner: Deloitte-US-Tax
          repositories: tto-sdt-infra

      - name: Checkout Project ${{ github.repository }}
        uses: actions/checkout@v6
        with:
          repository: ${{ github.repository }}
          path: "project"
          ref: "${{ github.ref_name }}"

      - name: Checkout shared infrastructure
        uses: actions/checkout@v6
        with:
          repository: Deloitte-US-Tax/tto-sdt-infra
          ref: aicc
          path: sdt-infra
          token: ${{ steps.app-token-sdt-repo.outputs.token }}

      - name: Resolve environment Azure credentials
        shell: bash
        run: |
          set -euo pipefail
          if [ -z "${AZURE_CREDENTIALS:-}" ]; then
            echo "::error::Azure credentials secret not found. Expected NPD_VIHAAN_AZURE_CREDENTIALS."
            exit 1
          fi

          echo "✅ Credentials resolved successfully"

      - name: Login to Azure with credentials JSON
        uses: azure/login@v3
        with:
          creds: ${{ env.AZURE_CREDENTIALS }}

      - name: Apply Bicep AICC
        id: apply-aicc
        uses: Deloitte-US-Tax/tto-sdt-infra/.github/actions/deployment/bicep-apply@aicc
        with:
          asset: aicc
          environment: ${{ inputs.environment }}
          resource_group: ${{ needs.plan.outputs.resource_group_aicc }}

  post-deployment:
    name: Post-Deployment
    if: ${{ always() && (needs.apply.outputs.outputs_present_aicc == 'true') }}
    needs:
      - init
      - plan
      - apply
    runs-on: ${{ needs.init.outputs.runner }}
    timeout-minutes: 30
    environment: ${{ inputs.environment }}
    env:
      AZURE_CREDENTIALS: ${{ secrets.NPD_VIHAAN_AZURE_CREDENTIALS }}
    steps:
      - name: Get GitHub App token for reusable workflows
        id: app-token-sdt-repo
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.APP_CI_GITHUB_ID }}
          private-key: ${{ secrets.APP_CI_GITHUB_PEM }}
          owner: Deloitte-US-Tax
          repositories: tto-sdt-infra

      - name: Checkout shared infrastructure
        uses: actions/checkout@v6
        with:
          repository: Deloitte-US-Tax/tto-sdt-infra
          ref: aicc
          path: sdt-infra
          token: ${{ steps.app-token-sdt-repo.outputs.token }}

      - name: Resolve environment Azure credentials
        shell: bash
        run: |
          set -euo pipefail
          if [ -z "${AZURE_CREDENTIALS:-}" ]; then
            echo "::error::Azure credentials secret not found. Expected NPD_VIHAAN_AZURE_CREDENTIALS."
            exit 1
          fi

          echo "✅ Credentials resolved successfully"

      - name: Login to Azure with credentials JSON
        uses: azure/login@v3
        with:
          creds: ${{ env.AZURE_CREDENTIALS }}

      - name: Manage PEP private DNS records
        id: manage-pep-dns
        uses: Deloitte-US-Tax/tto-sdt-infra/.github/actions/postdeployment/setup-pep-dns@aicc
        with:
          sdt_infra_dir: ${{ github.workspace }}/sdt-infra
2. configs/bicep/aicc/base.yml (replace everything)

# Base infrastructure for AI Code Checker (AICC). PBI 116430.
# Environment files set the resource group and subnetreference. Resources below use those subnet outputs.
# AICC is an independent solution hosted in the Vihaan NPD subscription: template specs and the
# tto-sdt-infra ref are its own pinned version "aicc". AKS follows tto-sdt-infra configs/bicep/shd.
# Design: ADO wiki "AI Checker Framework" > Infrastructure and Deployment (pages 14129-14131).

assetName: aicc
location: centralus
locationShort: usc

################################################################################
# Naming Conventions
################################################################################
namingconventions:
  # aicc prefix: azuscaicc<env>
  - deploy: true
    assetName: aicc
    tsVersion: aicc

################################################################################
# Resource Tags
# Same APM and billing values as the Vihaan stack; need to confirm if AICC has its own.
################################################################################
tags:
  - deploy: true
    name: base
    tsVersion: aicc
    appid: APM0038333
    billingcode: FPX16705-01-AI-AZ-8802
    groupcontact: USiCMSTax@deloitte.com
    primarycontact: jameschan@deloitte.com

################################################################################
# Managed Identities
# The generator sorts them by name and numbers them in that order, so they are listed alphabetically:
# managedidentity1_deploy = aks01-id, managedidentity2_deploy = otel01-id, managedidentity3_deploy = sbx01-id.
################################################################################
managedidentity:
  # 1. AKS control plane identity (subnet join, route table read, load balancer)
  - deploy: true
    tsVersion: aicc
    name: aks01-id
    tags: "union(tags_deploy.outputs.resultTags, { DESCRIPTION: 'AICC AKS control plane identity' })"

  # 2. OpenTelemetry collector identity (telemetry ingestion only; the sandbox cannot reach ingestion)
  - deploy: true
    tsVersion: aicc
    name: otel01-id
    tags: "union(tags_deploy.outputs.resultTags, { DESCRIPTION: 'AICC OpenTelemetry collector identity' })"

  # 3. Sandbox Workload Identity: Foundry inference only. Federation to the sandbox service account
  #    and the Foundry role are added once the namespace and Foundry exist (PBI 116430 tasks 7 and 8).
  - deploy: true
    tsVersion: aicc
    name: sbx01-id
    tags: "union(tags_deploy.outputs.resultTags, { DESCRIPTION: 'AICC sandbox workload identity' })"

################################################################################
# Network
#
# The VNet, subnets and route table belong to ITS (AZRG-ALL-ITS-VNET-SYS / AZRG-ALL-ITS-CORE-SYS)
# and are only referenced here, as in tax-vihaan-ai-infra. Verified 2026-11-11:
#   aks      AICCaks-subnet   10.202.62.128/26  AKS system + runner pools
#   sandbox  AICCshd2-subnet  10.202.62.192/27  AKS sandbox pool (untrusted, kept separate)
#   pep      AICCshd-subnet   10.202.62.64/26   private endpoints
# All three use RT-CUS: 0.0.0.0/0 -> hub appliance 10.152.6.52, so AKS uses userDefinedRouting.
# No NSG is attached today. NSGs and egress rules are open with ITS (task 3), so none are deployed here yet.
################################################################################
resourceroleassignment:
  # AKS identity needs Network Contributor on the VNet to join subnets (same as configs/bicep/shd).
  # The deployment SPN needs rights to assign roles in AZRG-ALL-ITS-VNET-SYS; if it has none, ITS grants this instead.
  - deploy: true
    tsVersion: aicc
    skipNamingConvention: true
    scope: resourceGroup('AZRG-ALL-ITS-VNET-SYS')
    name: guid(resourceGroup, 'aicc-aks-mi-vnet-contributor')
    principalId: managedidentity1_deploy.outputs.principalId
    resourceId: subnetreference_deploy.outputs.vnetId
    roleDefinitionId: 4d97b98b-1d4f-4787-a291-c67834d212e7 # Network Contributor
    principalType: ServicePrincipal

################################################################################
# Monitoring
################################################################################
loganalytics:
  deploy: true
  tsVersion: aicc
  name: log01
  skuName: PerGB2018
  dailyQuotaGb: 50
  dataRetention: 30
  features:
    enableLogAccessUsingOnlyResourcePermissions: true
  tags: tags_deploy.outputs.resultTags

################################################################################
# Key Vault: platform secrets only (GitHub App key, TLS material).
# No sandbox GitHub token and no Foundry API key are stored here.
################################################################################
keyvault:
  - deploy: true
    tsVersion: aicc
    name: kv01
    sku: standard
    enableRbacAuthorization: true
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enableVaultForDiskEncryption: false
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: Disabled
    networkAcls:
      bypass: AzureServices
      defaultAction: Deny
    diagnosticSettings:
      - name: _namingconventions_kv01-ds
        workspaceResourceId: loganalytics_deploy.outputs.resourceId
        metricCategories:
          - category: AllMetrics
        logCategoriesAndGroups:
          - category: AuditEvent
    privateEndpoints:
      - name: _namingconventions_kv01-pep
        privateLinkServiceConnectionName: _namingconventions_kv01-pep-plc
        customNetworkInterfaceName: _namingconventions_kv01-pep-nic
        subnetResourceId: subnetreference_deploy.outputs.subnets.pep
        isManualConnection: false
    tags: "union(tags_deploy.outputs.resultTags, { DESCRIPTION: 'AICC platform Key Vault' })"

################################################################################
# Container registry: approved agent images, pulled by digest.
# Private only, no admin user. Retention is off so release-pinned digests are never purged.
################################################################################
acr:
  deploy: true
  tsVersion: aicc
  name: cr01
  acrSku: Premium
  acrAdminUserEnabled: false
  anonymousPullEnabled: false
  zoneRedundancy: Disabled
  publicNetworkAccess: Disabled
  retentionPolicyStatus: disabled
  roleAssignments:
    # Kubelet identity pulls images (sandbox identity does not)
    - roleDefinitionIdOrName: AcrPull
      principalType: ServicePrincipal
      principalId: aks_deploy.outputs.kubeletIdentityObjectId
  diagnosticSettings:
    - name: _namingconventions_cr01-ds
      workspaceResourceId: loganalytics_deploy.outputs.resourceId
      metricCategories:
        - category: AllMetrics
      logCategoriesAndGroups:
        - category: ContainerRegistryLoginEvents
        - category: ContainerRegistryRepositoryEvents
  privateEndpoints:
    - name: _namingconventions_cr01-pep
      privateLinkServiceConnectionName: _namingconventions_cr01-pep-plc
      customNetworkInterfaceName: _namingconventions_cr01-pep-nic
      subnetResourceId: subnetreference_deploy.outputs.subnets.pep
      isManualConnection: false
  tags: "union(tags_deploy.outputs.resultTags, { DESCRIPTION: 'AICC agent image registry' })"

################################################################################
# AKS
#
# Same configuration as the SDT cluster (tto-sdt-infra configs/bicep/shd) except the agent pools,
# and without Istio. A private cluster is not possible (no permission to manage private DNS), so the
# API server is public but restricted to the SDT authorized IP ranges (VDI, F5, VPN) plus Entra ID RBAC.
# Azure CNI Overlay (pods do not use VNet IPs), Cilium, OIDC issuer + Workload Identity, KEDA,
# outbound through the ITS route table. podCidr / serviceCidr / dnsServiceIP are set per environment.
#
# Pools:
#   syspool     System  AICCaks-subnet   cluster add-ons only
#   runnerpool  User    AICCaks-subnet   ARC GitHub runners (trusted)
#   sbxpool     User    AICCshd2-subnet  review sandbox pods (untrusted), tainted
# Kata (follow-up task 9): the sandbox pool already uses Azure Linux and a Gen2 size that supports
# nested virtualization; once PBI 2 enables it, add workloadRuntime: KataVmIsolation and recreate the pool.
################################################################################
aks:
  deploy: true
  tsVersion: aicc
  name: aks01
  skuTier: Standard
  networkPlugin: azure
  networkPluginMode: overlay
  networkDataplane: cilium
  networkPolicy: cilium
  loadBalancerSku: standard
  outboundType: userDefinedRouting
  disableLocalAccounts: false
  publicNetworkAccess: Enabled
  enableOidcIssuerProfile: true
  securityProfile:
    workloadIdentity:
      enabled: true
  kubernetesVersion: "1.36.4"
  enableStorageProfileBlobCSIDriver: true
  enableStorageProfileDiskCSIDriver: true # per-run review storage is a PVC
  enableStorageProfileFileCSIDriver: true
  enableKeyvaultSecretsProvider: true
  azurePolicyEnabled: true
  # KEDA scales the ARC runners and other event-driven workloads.
  workloadAutoScalerProfile:
    keda:
      enabled: true
  autoUpgradeProfile:
    upgradeChannel: stable
    nodeOSUpgradeChannel: Unmanaged
  apiServerAccessProfile:
    enablePrivateCluster: false
    authorizedIPRanges:
      # VDI Azure West EU
      - 137.117.157.234/32
      - 20.4.239.139/32
      - 54.170.90.26/32
      - 34.253.51.206/32
      # VDI AWS AP South - Mumbai
      - 15.206.135.19/32
      - 3.108.243.239/32
      - 65.2.94.192/32
      - 15.206.236.118/32
      # VDI AWS EU Central - Frankfurt
      - 18.196.36.202/32
      - 3.121.96.241/32
      - 63.176.18.5/32
      - 3.126.212.130/32
      # VDI Azure US East2 Hub3
      - 172.177.250.223/32
      - 20.62.109.28/32
      # VDI AWS US East 1 - North Virginia
      - 52.1.20.86/32
      - 35.153.14.105/32
      - 100.29.213.145/32
      - 44.207.200.216/32
      # VDI AWS US West - Oregon
      - 35.83.164.228/32
      - 52.10.5.196/32
      # VDI Azure India Central
      - 4.213.88.120/32
      - 20.219.0.241/32
      # VDI Tokyo
      - 52.196.25.60/32
      - 18.180.245.180/32
      # VDI Sydney
      - 15.134.181.46/32
      - 15.134.59.231/32
      # VDI West US 2
      - 34.212.52.76/32
      - 54.184.33.171/32
      # VDI ILC1 (Israel)
      - 51.84.93.47/32
      - 51.84.62.69/32
      # F5 East US 2
      - 20.36.222.90/32
      - 40.67.153.130/32
      - 20.94.7.151/32
      - 20.1.132.238/32
      - 20.246.35.154/32
      # F5 Central US
      - 13.86.34.113/32
      - 13.86.126.217/32
      - 168.61.220.217/32
      # USI India North VPN
      - 130.41.114.83/32
      - 130.41.114.84/32
      - 130.41.114.174/32
      - 130.41.114.175/32
      - 130.41.114.176/32
      - 130.41.114.177/32
      - 130.41.114.178/32
      - 130.41.114.179/32
      - 130.41.114.212/32
      - 130.41.114.214/32
      - 130.41.114.224/32
      - 130.41.114.227/32
      - 130.41.114.246/32
      - 130.41.114.247/32
      # US Northeast VPN
      - 128.77.43.73/32
      - 128.77.43.74/32
      - 130.41.168.204/32
      - 130.41.168.205/32
      - 134.238.185.222/32
      - 134.238.185.223/32
      - 165.1.206.238/32
      - 165.1.206.239/32
      - 165.85.44.206/32
      - 165.85.45.195/32
      - 165.85.45.196/32
      - 165.85.139.98/32
      # US East VPN
      - 128.77.41.153/32
      - 128.77.41.154/32
      - 130.41.110.51/32
      - 130.41.110.249/32
      - 130.41.111.69/32
      - 130.41.111.70/32
      - 137.83.217.28/32
      - 137.83.217.29/32
      - 137.83.217.135/32
      - 137.83.222.125/32
      - 165.1.207.174/32
      - 165.1.207.176/32
  aadProfile:
    enableAzureRBAC: true
    managed: true
    adminGroupObjectIDs:
      - 7164c319-fa3e-4fd6-bebc-0a1bd67d96c8 # SG-US csdtax admin
      - 4c9e96a4-7aa4-4bf4-a622-23e0ce3dde97 # SG-US TaxCTO-Devops
  managedIdentities:
    userAssignedResourceIds:
      - managedidentity1_deploy.outputs.resourceId
  primaryAgentPoolProfiles:
    - name: syspool
      count: 2
      mode: System
      vmSize: Standard_D4ads_v5
      osType: Linux
      osSKU: AzureLinux
      osDiskType: Ephemeral
      maxPods: 110
      vnetSubnetResourceId: subnetreference_deploy.outputs.subnets.aks
      nodeTaints:
        - "CriticalAddonsOnly=true:NoSchedule"
  agentPools:
    # ARC runner pool (trusted side)
    - name: runnerpool
      count: 1
      enableAutoScaling: true
      minCount: 1
      maxCount: 3
      mode: User
      vmSize: Standard_D4ads_v5
      osType: Linux
      osSKU: AzureLinux
      osDiskType: Ephemeral
      maxPods: 110
      vnetSubnetResourceId: subnetreference_deploy.outputs.subnets.aks
      nodeLabels:
        aicc/role: runner
      nodeTaints:
        - "aicc/runner=true:NoSchedule"
    # Sandbox pool (untrusted side). Standard runtime until Kata is approved.
    - name: sbxpool
      count: 1
      enableAutoScaling: true
      minCount: 1
      maxCount: 3
      mode: User
      vmSize: Standard_D4s_v5
      osType: Linux
      osSKU: AzureLinux
      maxPods: 30
      vnetSubnetResourceId: subnetreference_deploy.outputs.subnets.sandbox
      nodeLabels:
        aicc/role: sandbox
      nodeTaints:
        - "aicc/sandbox=true:NoSchedule"
      # workloadRuntime: KataVmIsolation   # task 9, after PBI 2
  monitoringWorkspaceResourceId: loganalytics_deploy.outputs.resourceId
  omsAgentEnabled: true
  azureMonitorProfile:
    metrics:
      enabled: true
  diagnosticSettings:
    - name: _namingconventions_aks01-ds
      workspaceResourceId: loganalytics_deploy.outputs.resourceId
      metricCategories:
        - category: AllMetrics
      logCategoriesAndGroups:
        - category: guard
        - category: kube-apiserver
        - category: kube-audit-admin
        - category: kube-controller-manager
        - category: kube-scheduler
        - category: cluster-autoscaler
  tags: tags_deploy.outputs.resultTags

################################################################################
# Outputs: consumed by setup-pep-dns in the post-deployment job (central private DNS records).
################################################################################
outputs:
  - name: kv01-pep
    deploy: true
    value:
      id: keyvault1_deploy.outputs.privateEndpoints[0].resourceId
      zone: privatelink.vaultcore.azure.net
  - name: cr01-registry-pep
    deploy: true
    value:
      id: acr_deploy.outputs.privateEndpoints[0].resourceId
      zone: privatelink.azurecr.io
3. configs/bicep/aicc/dev.yml (replace everything)

# DEV environment. Inherits from base.yml.
# Subscription US-AZSUB-AME-TAX-VIHAANAI-NPD, service principal US VIHAANAI INFRA NONPROD.
# Resource group follows AZRG-<locationShort>-TAX-<assetName>-<environment>.

environment: dev
resourceGroup: AZRG-USC-TAX-AICC-DEV

tags:
  - name: base
    env: NPD

subnetreference:
  deploy: true
  tsVersion: aicc
  vnetName: VNET-CUS-VIHAAN-10.202.59.32-27
  resourceGroupName: AZRG-ALL-ITS-VNET-SYS
  subnets:
    aks: AICCaks-subnet
    sandbox: AICCshd2-subnet
    pep: AICCshd-subnet

keyvault:
  - name: kv01
    roleAssignments:
      # SG-US csdtax admin
      - roleDefinitionIdOrName: Key Vault Administrator
        principalType: Group
        principalId: 7164c319-fa3e-4fd6-bebc-0a1bd67d96c8
      # SG-US TaxCTO-Devops
      - roleDefinitionIdOrName: Key Vault Administrator
        principalType: Group
        principalId: 4c9e96a4-7aa4-4bf4-a622-23e0ce3dde97

# Overlay ranges are internal to the cluster and not routed on the VNet.
# Outside 10.0.0.0/8 so they cannot shadow corporate 10.x destinations pods must reach, and not
# 192.168.0.0/16, which is common on home/office networks and could clash with VPN or client ranges.
aks:
  podCidr: 172.16.0.0/16
  serviceCidr: 172.20.0.0/16
  dnsServiceIP: 172.20.0.10
4. README.md (replace everything)
Save it as UTF-8. In VS Code, check the bottom-right corner shows "UTF-8"; if it shows "UTF-16 LE", click it → Save with Encoding → UTF-8.


# tax-vihaan-aicc-infra

Infrastructure for AI Code Checker (AICC), PBI 116430. AICC is an independent solution hosted in the Vihaan NPD subscription. YAML configs are turned into Bicep by the generator in `tto-sdt-infra`; the `tto-sdt-infra` ref and every module's template spec version are pinned to `aicc`. Design: ADO wiki *AI Checker Framework* > Infrastructure and Deployment.

## Deployment workflow

[Deploy AICC Infrastructure](.github/workflows/deploy-bicep-infrastructure.yaml), manual, environment `dev`. One asset, so everything is in one workflow (same layout as `tax-ai-library-infra`):

1. **Init**: resolve the runner with the shared SDT workflow.
2. **Plan-Validate**: generate Bicep from `configs/bicep/aicc`, validate, what-if. Creates the resource group if missing.
3. **Approve**: shared SDT approval workflow (`approve_dev` environment).
4. **Apply**.
5. **Post-Deployment**: `setup-pep-dns` registers private endpoint DNS records from the `outputs` section.

Required: secret `NPD_VIHAAN_AZURE_CREDENTIALS` (service principal `US VIHAANAI INFRA NONPROD`), GitHub environments `dev` and `approve_dev`. `APP_CI_GITHUB_PEM` and `APP_CI_GITHUB_ID` come from the organization.

## Subscription and resource group

| Environment | Subscription | Resource group | Region |
|---|---|---|---|
| `dev` | `US-AZSUB-AME-TAX-VIHAANAI-NPD` | `AZRG-USC-TAX-AICC-DEV` | Central US |

## Network

VNet `VNET-CUS-VIHAAN-10.202.59.32-27` in `AZRG-ALL-ITS-VNET-SYS` (owned by ITS, referenced only). Route table `RT-CUS` (ITS) is already on the subnets and sends `0.0.0.0/0` to the hub appliance `10.152.6.52`.

| Key | Subnet | Address | Used by |
|---|---|---|---|
| `aks` | `AICCaks-subnet` | `10.202.62.128/26` | AKS system and runner pools |
| `sandbox` | `AICCshd2-subnet` | `10.202.62.192/27` | AKS sandbox pool |
| `pep` | `AICCshd-subnet` | `10.202.62.64/26` | Private endpoints |

NSGs, route table, Azure Firewall and DCR/DCE are pending decisions and not in this config yet.

## Resources

| Resource | Notes |
|---|---|
| AKS `aks01` | Same as the SDT cluster except the agent pools, without Istio. Public API restricted to the SDT authorized IP ranges (no private DNS permission for a private cluster), Entra ID RBAC, Azure CNI Overlay, Cilium, OIDC + Workload Identity, KEDA, Key Vault secrets provider, Blob/Disk/File CSI drivers, outbound via the ITS route table. Pools: `syspool` (system), `runnerpool` (ARC runners), `sbxpool` (sandbox, tainted, Azure Linux). |
| ACR `cr01` | Premium, private endpoint, no admin user, no public access; kubelet identity has AcrPull. |
| Key Vault `kv01` | RBAC, private endpoint, purge protection; platform secrets only. |
| Log Analytics `log01` | Container Insights and diagnostic settings for every resource. |
| Managed identities | `aks01-id` (cluster), `otel01-id` (OTel collector), `sbx01-id` (sandbox Workload Identity). |

Per-run review storage is a Kubernetes PVC (Disk CSI driver), so there is no storage account.

## Follow-ups (outside this config)

- Ingress mechanism, NSGs and route table, Firewall Premium (task 3), DCR/DCE for AKS monitoring.
- Namespaces, ARC, approved-image admission, quotas, NetworkPolicy, OTel collector (task 7).
- Foundry private endpoint and sandbox federation / Foundry role (task 8, needs PBI 1).
- Kata: add `workloadRuntime: KataVmIsolation` to `sbxpool` and recreate it (task 9, needs PBI 2).

## Generate locally

```bash
python3 ../tto-sdt-infra/scripts/generate-bicep/generate-bicep-files.py \
  --config configs/bicep/aicc/dev.yml \
  --base-config configs/bicep/aicc/base.yml \
  --modules-dir ../tto-sdt-infra/bicep/modules \
  --output-dir bicep \
  --env dev
```

The generator also writes `configs/bicep/aicc/schema.json`; do not commit it.
Files that stay as they are: .github/CODEOWNERS and the three bicep/bicepconfig-*.json.

Once all 6 changes are in place on the branch, commit with something like Apply review comments: aicc ref, SDT AKS settings, single workflow and push. PR #1 then updates.

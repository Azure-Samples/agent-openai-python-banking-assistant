// ============================================================================
// AI Landing Zone Bicep Deployment Template
// This infrastructure-as-code template follows best practices for modular,
// reusable, and configuration-aware deployments. Key principles:
//
// - **AZD Integration**: This template is optimized for use with the Azure Developer CLI (`azd`).
//   Use `azd provision` to deploy infrastructure and `azd deploy` to deploy your application.
//   It supports automated, repeatable, and configuration-aware workflows. The `main.json` file
//   can include placeholders (e.g., `${AZURE_LOCATION}`, `${AZURE_PRINCIPAL_ID}`) that are automatically
//   injected by `azd` during execution, enabling seamless parameter resolution.
//
// - **Parameterization**: All configuration values are defined in `main.json`.
//   You can create multiple parameter files to support different deployment configurations,
//   such as variations in scale, resource combinations, or cost constraints.
//
// - **Feature Flags**: Resource provisioning is modular and controlled via feature flags
//   (e.g., `deployAppConfig`). This enables selective deployment of components based on project needs.
//
// - **Azure Verified Modules (AVM)**: Official AVM modules are used as the foundation
//   for resource deployment, ensuring consistency, maintainability, and alignment with Microsoft standards.
//   Reference: https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/
//   When AVM does not cover a specific resource, custom Bicep module is used as fallback.
//
// - **Output Exposure**: Key outputs such as connection strings, endpoints, and resource IDs
//   are exposed as Bicep outputs and can be consumed by downstream processes or deployment scripts.
//
// - **Post-Provisioning Automation**: Supports optional post-provisioning scripts to perform data plane
//   operations or additional configurations. These scripts can run independently or as `azd` hooks,
//   enabling fine-grained control and custom automation after infrastructure deployment.
//
// ============================================================================

targetScope = 'resourceGroup'

//////////////////////////////////////////////////////////////////////////
// PARAMETERS
//////////////////////////////////////////////////////////////////////////

// Important notes about parameters:
// 1) Before running azd provision, set parameter values using main.parameters.json or 
// the command line: azd env set ENV_VARIABLE_NAME value, for parameters configured to allow substitution.
//
// 2) You can identify these substitutable parameters in main.parameters.json by this format:
// "parameterName": { "value": "${ENV_VARIABLE_NAME}" }.
// This allows the convenience of setting values via the command line (e.g., azd env set ENV_VARIABLE_NAME true).
//
// 3) Substitutable parameters: if an environment variable isn’t set before running `azd provision`, its value will be empty.
// To prevent this, each parameter that uses the substitution mechanism has a corresponding Bicep variable (`_parameterName`) with a default value.
// When adding new substitutable parameters in this Bicep file or in `main.parameters.bicep`, follow the same pattern.

// ---------------------------------------------------------------------
// Imports
// ----------------------------------------------------------------------
import * as const from 'constants/constants.bicep'

// ----------------------------------------------------------------------
// General Parameters
// ----------------------------------------------------------------------

@description('Name of the Azure Developer CLI environment')
param environmentName string

@description('The Azure region where your resources will be created.')
param location string = resourceGroup().location

@description('The Azure region where Cosmos DB will be created. Defaults to the resource group location.')
param cosmosLocation string = resourceGroup().location

@description('The Azure region where Azure AI Search services will be created. Defaults to the main deployment location. Override this when the primary region is out of capacity for AI Search.')
param searchServiceLocation string = ''

@description('The Azure region where the Azure AI Speech service will be created. Defaults to the main deployment location.')
param speechServiceLocation string = ''

@description('Principal ID for role assignments. This is typically the Object ID of the user or service principal running the deployment.')
param principalId string

@description('Principal type for role assignments. This can be "User", "ServicePrincipal", or "Group".')
param principalType string = 'User'

@description('Tags to apply to all resources in the deployment')
param deploymentTags object = {}

@description('Label used for App Configuration key-value pairs.')
param appConfigLabel string = 'ai-lz'

@description('Enable network isolation for the deployment. This will restrict public access to resources and require private endpoints where applicable.')
param networkIsolation bool = false

@description('Gap 8 — Deployment topology preset. Required to surface deployment intent explicitly. Allowed values: `standalone` (default — self-contained spoke, own firewall/bastion/NAT GW; suitable for sandbox or single-team subscriptions) or `ailz-integrated` (spoke designed to plug into an Azure Landing Zone-managed hub; consumer is expected to provide `hubIntegrationHubVnetResourceId`, `hubIntegrationEgressNextHopIp` and/or `hubIntegrationExistingRouteTableResourceId`, BYO Private DNS overrides, and optionally `existingLogAnalyticsWorkspaceResourceId` for centralized observability). The value is captured as a `deploymentMode` tag on the resource group so platform teams can audit deployment posture. The preset does NOT automatically override explicit operator flags; it primarily documents intent and powers the pre-flight script (`scripts/Invoke-PreflightChecks.ps1`, Gap 9).')
@allowed([
  'standalone'
  'ailz-integrated'
])
param deploymentMode string = 'standalone'

@description('Optional. When non-empty, opens each services public surface restricted to these CIDRs via native `ipRules` / `networkAcls.ipRules`. Empty (default) means no public allow-list. Applied to Storage, Key Vault, Cosmos DB, AI Search, Container Registry, and the AI Foundry / Cognitive Services accounts. App Configuration and Application Insights do not expose native ipRules and ignore this parameter (documented in docs/v2-migration.md). When `networkIsolation=true` AND `allowedIpRanges` is non-empty, services are switched to `publicNetworkAccess=Enabled` so the IP rules can take effect (defense-in-depth alongside private endpoints).')
param allowedIpRanges string[] = []

@description('''When set to true, Private DNS Zones and DNS zone groups will NOT be created by this module.
Use this option in environments where Azure Policy automatically manages Private DNS Zone linking for private endpoints
(e.g., CAF Enterprise-Scale Platform Landing Zone). Creating DNS zones in those environments causes conflicts with
policy-driven DNS management and results in deployment failures.
When false (default), the module creates and manages all Private DNS Zones and links them to the VNet.
Requires networkIsolation to be true to have any effect.''')
param policyManagedPrivateDns bool = false

// ----------------------------------------------------------------------
// Gap 2 — BYO Private DNS Zones (granular per-namespace overrides)
// ----------------------------------------------------------------------
// For each Private DNS zone the landing zone normally creates, an
// `existingPrivateDnsZone<Namespace>ResourceId` param accepts a full
// resource ID. When provided:
//   * The zone is NOT created by this deployment.
//   * The zone is NOT linked from the spoke VNet (assumed pre-linked via
//     the hub or another mechanism; cross-RG linking is an operator task
//     in v2.0.0 — see docs/v2-migration.md).
//   * The provided resource ID is used directly in every Private
//     Endpoint DNS Zone Group that consumes the zone, so PE→FQDN
//     resolution still works against the shared zone.
// `policyManagedPrivateDns=true` continues to win — when it is set,
// neither creation nor linking happens for any zone regardless of these
// BYO params (the pre-flight script flags this as a misconfiguration).

@description('Gap 2 — Resource ID of an existing `privatelink.cognitiveservices.azure.com` Private DNS Zone to reuse (Azure AI Foundry / Cognitive Services PE DNS). When set, the local zone is not created. Pre-link the zone to the spoke VNet (or rely on hub→spoke peering + hub-side link) — automatic spoke linking is not performed.')
param existingPrivateDnsZoneCogSvcsResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.openai.azure.com` Private DNS Zone to reuse (Azure OpenAI PE DNS).')
param existingPrivateDnsZoneOpenAiResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.services.ai.azure.com` Private DNS Zone to reuse (AI Services / Foundry PE DNS).')
param existingPrivateDnsZoneAiServicesResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.search.windows.net` Private DNS Zone to reuse (Azure AI Search PE DNS).')
param existingPrivateDnsZoneSearchResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.documents.azure.com` Private DNS Zone to reuse (Azure Cosmos DB PE DNS).')
param existingPrivateDnsZoneCosmosResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.blob.<storage suffix>` Private DNS Zone to reuse (Azure Storage Blob PE DNS).')
param existingPrivateDnsZoneBlobResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.vaultcore.azure.net` Private DNS Zone to reuse (Azure Key Vault PE DNS).')
param existingPrivateDnsZoneKeyVaultResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.azconfig.io` Private DNS Zone to reuse (Azure App Configuration PE DNS).')
param existingPrivateDnsZoneAppConfigResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.<region>.azurecontainerapps.io` Private DNS Zone to reuse (Azure Container Apps PE DNS). Region-specific zone — must match the deployment region.')
param existingPrivateDnsZoneContainerAppsResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.azurecr.io` Private DNS Zone to reuse (Azure Container Registry PE DNS).')
param existingPrivateDnsZoneAcrResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.monitor.azure.com` Private DNS Zone to reuse (Azure Monitor Private Link Scope PE DNS).')
param existingPrivateDnsZoneAzureMonitorResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.oms.opinsights.azure.com` Private DNS Zone to reuse (OMS Log Analytics PE DNS).')
param existingPrivateDnsZoneOmsOpsInsightsResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.ods.opinsights.azure.com` Private DNS Zone to reuse (ODS Log Analytics ingestion PE DNS).')
param existingPrivateDnsZoneOdsOpsInsightsResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.agentsvc.azure.automation.net` Private DNS Zone to reuse (Azure Monitor agent service PE DNS).')
param existingPrivateDnsZoneAzureAutomationResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.applicationinsights.io` Private DNS Zone to reuse. Only consumed when `enablePrivateLogAnalytics=true` and AMPLS is created locally; otherwise this BYO ID is ignored.')
param existingPrivateDnsZoneAppInsightsResourceId string?

@description('The Azure region where private endpoints will be created. Defaults to the main deployment location. Use this when your VNet is in a different region than the resources.')
param privateEndpointLocation string = ''

@description('The name of the resource group where private endpoints will be created. When empty, private endpoints are placed in the VNet resource group (for existing VNets with sideBySideDeploy disabled) or the deployment resource group.')
param privateEndpointResourceGroupName string = ''

@description('Use an existing Virtual Network. When false, a new VNet will be created.')
param useExistingVNet bool = false

@description('The full ARM resource ID of an existing Virtual Network. Format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.Network/virtualNetworks/{vnetName}. Leave empty to create a new VNet.')
param existingVnetResourceId string = ''

param agentSubnetName string = 'agent-subnet'
param peSubnetName string = 'pe-subnet'
param gatewaySubnetName string = 'gateway-subnet'
param azureBastionSubnetName string = 'AzureBastionSubnet'
param azureFirewallSubnetName string = 'AzureFirewallSubnet'
param azureAppGatewaySubnetName string = 'AppGatewaySubnet'
param jumpboxSubnetName string = 'jumpbox-subnet'
param acaEnvironmentSubnetName string = 'aca-environment-subnet'
param devopsBuildAgentsSubnetName string = 'devops-build-agents-subnet'

@description('Address prefixes for the virtual network.')
param vnetAddressPrefixes array = [
  '192.168.0.0/21' // 192.168.0.0 – 192.168.7.255 (2048 IPs total)
]

@description('Gap 3 — Optional suffix appended to every Private DNS zone VNet link name created by this deployment. Set to a unique value (e.g., the spoke name or environment short-code) when multiple spokes link to the same shared Private DNS zone — without a unique suffix the link name collides and the second deployment fails. Leave empty for single-spoke or non-shared-zone deployments. Final link name: `<vnetName>-<zone-shortcode>-link<suffix>[<-byon if useExistingVNet>]`. Forbidden characters per Microsoft.Network/privateDnsZones/virtualNetworkLinks: must be 1–80 chars, alphanumeric / hyphens / underscores only.')
param dnsZoneLinkSuffix string = ''

//
// Subnet allocations (non-overlapping, optimized for production workloads)
// PE subnet increased to /26 to support multiple Private Endpoints without race conditions
//

@description('AI Foundry Agents subnet — Recommended /24 (256 IPs)')
param agentSubnetPrefix string = '192.168.0.0/24' // 192.168.0.0–192.168.0.255

@description('Azure Container Apps Environment subnet — /24 (256 IPs)') // Recommended minimum is /23
param acaEnvironmentSubnetPrefix string = '192.168.1.0/24' // 192.168.1.0–192.168.1.255

@description('Private Endpoints subnet — /26 (64 IPs) — Increased to prevent race conditions during parallel PE creation')
param peSubnetPrefix string = '192.168.2.0/26' // 192.168.2.0–192.168.2.63

@description('Azure Bastion subnet — Required /26 (64 IPs, CIDR-aligned)')
param azureBastionSubnetPrefix string = '192.168.2.64/26' // 192.168.2.64–192.168.2.127

@description('Azure Firewall subnet — /26 (64 IPs, CIDR-aligned)')
param azureFirewallSubnetPrefix string = '192.168.2.128/26' // 192.168.2.128–192.168.2.191

@description('Gateway subnet — Required /26 (64 IPs, CIDR-aligned)')
param gatewaySubnetPrefix string = '192.168.2.192/26' // 192.168.2.192–192.168.2.255

@description('Application Gateway subnet — /27 (32 IPs)')
param azureAppGatewaySubnetPrefix string = '192.168.3.0/27' // 192.168.3.0–192.168.3.31

@description('Jumpbox subnet — /27 (32 IPs)')
param jumpboxSubnetPrefix string = '192.168.3.64/27' // 192.168.3.64–192.168.3.95

@description('DevOps Build Agents subnet — /27 (32 IPs)')
param devopsBuildAgentsSubnetPrefix string = '192.168.3.96/27' // 192.168.3.96–192.168.3.127

// ----------------------------------------------------------------------
// Feature-flagging Params (as booleans with a default of true)
// ----------------------------------------------------------------------

// @description('If false, skips creating platform infrastructure such as Firewall, Jumpbox, Bastion, etc.')
// param greenFieldDeployment bool = true

@description('Whether to deploy Bing-powered grounding capabilities alongside your AI services.')
param deployGroundingWithBing bool = true

@description('Deploy Azure AI Foundry for building and managing AI models.')
param deployAiFoundry bool = true

@description('Deploy Azure AI Foundry agent subnet.')
param deployAiFoundrySubnet bool = true

@description('Deploy Azure App Configuration for centralized feature-flag and configuration management.')
param deployAppConfig bool = true

@description('Deploy an Azure Key Vault to securely store secrets, keys, and certificates.')
param deployKeyVault bool = true

@description('Deploy an Azure Key Vault to securely store VM secrets, keys, and certificates.')
param deployVmKeyVault bool = true

@description('Deploy an Azure Log Analytics workspace for centralized log collection and query.')
param deployLogAnalytics bool = true

@description('Resource ID of an existing Log Analytics workspace to reuse instead of creating one (Gap 5). When non-empty, no LAW is created in this deployment and all diagnostic settings, AMPLS linkage, and App Configuration entries point at this central workspace. Cross-RG and cross-subscription IDs are supported.')
param existingLogAnalyticsWorkspaceResourceId string?

@description('When network isolation is enabled, also deploy an Azure Monitor Private Link Scope (AMPLS) with private endpoints and the related monitor/opinsights/automation private DNS zones to keep Log Analytics + Application Insights traffic on the private network. Disable to opt-out and avoid sharing those Azure Monitor private DNS zones with other workloads (preventing cross-workload DNS conflicts). Has no effect when networkIsolation is false or when an `existingLogAnalyticsWorkspaceResourceId` is provided (the central workspace is assumed to be private-linked centrally).')
param enablePrivateLogAnalytics bool = true

@description('Deploy Azure Application Insights for application performance monitoring and diagnostics.')
param deployAppInsights bool = true

@description('Resource ID of an existing Application Insights component to reuse instead of creating one (Gap 5). Pair with `existingApplicationInsightsConnectionString` so downstream consumers (Container Apps Environment, App Configuration) receive a working connection string without requiring same-RG access to the existing component. Cross-RG/cross-subscription IDs are supported.')
param existingApplicationInsightsResourceId string?

@description('Connection string for the existing Application Insights component referenced by `existingApplicationInsightsResourceId`. Required when reusing AppInsights so the Container Apps Environment and the `APPLICATIONINSIGHTS_CONNECTION_STRING` App Configuration entry are correctly populated. Operators retrieve this from `az monitor app-insights component show -g <rg> -a <name> --query connectionString -o tsv`.')
@secure()
param existingApplicationInsightsConnectionString string?

@description('When `existingApplicationInsightsResourceId` is provided WITHOUT a matching `existingLogAnalyticsWorkspaceResourceId`, the deployment normally fails the pre-flight check (Gap 5 §4.13) because telemetry would split between the central AppInsights workspace and this deployment\'s own LAW. Set to `true` only if the split is intentional and accepted.')
param allowMixedObservabilityWorkspaces bool = false

@description('Gap 6 — IP address of an external network virtual appliance (typically the hub Azure Firewall private IP) that should receive the spoke 0.0.0.0/0 default route when no spoke-local firewall is deployed. Effective only when `deployAzureFirewall=false`, `networkIsolation=true`, and no `hubIntegrationExistingRouteTableResourceId` is provided. Use this in AI-LZ-integrated topologies where the hub provides centralized egress filtering.')
param hubIntegrationEgressNextHopIp string?

@description('Gap 6 — Resource ID of an existing Route Table to attach the spoke workload subnets to. When set, the deployment skips creation of its local route table and reuses this RT (assumed pre-configured with the correct default route). Required for Landing Zone-managed topologies where the platform team owns the spoke RT. Mutually exclusive with `hubIntegrationEgressNextHopIp` (which builds a local RT). When set, both `deployAzureFirewall` and any local default-route creation are suppressed.')
param hubIntegrationExistingRouteTableResourceId string?

@description('Gap 7 — Resource ID of the hub Virtual Network the spoke should peer with. When set and `hubIntegrationCreateHubPeering=true`, the deployment creates a spoke→hub VNet peering. The reverse (hub→spoke) peering is the operator\'s responsibility — typically handled by a platform team script (`tests/scripts/Add-HubSpokePeering.ps1` for our test harness). Hub VNet may live in a different subscription/RG; the peering resource itself lives in the spoke VNet so the spoke deployment has the rights to create it.')
param hubIntegrationHubVnetResourceId string?

@description('Gap 7 — When true and `hubIntegrationHubVnetResourceId` is set, the deployment creates the spoke→hub peering inline. Set to `false` to defer peering creation entirely to the platform team (both directions handled externally). Only effective when the spoke VNet is created by this deployment (`useExistingVNet=false`); with BYO VNet, peering management is the operator\'s responsibility.')
param hubIntegrationCreateHubPeering bool = true

@description('Gap 7 — `allowGatewayTransit` flag on the spoke→hub peering. Set to `true` when the spoke owns a VPN/ExpressRoute gateway that the hub should be allowed to use as transit. Defaults to `false` (hub-owned gateway is the standard topology).')
param hubIntegrationPeeringAllowGatewayTransit bool = false

@description('Gap 7 — `useRemoteGateways` flag on the spoke→hub peering. Set to `true` to route on-premises traffic from the spoke through the hub-owned VPN/ExpressRoute gateway. Requires the reverse hub→spoke peering to have `allowGatewayTransit=true` and a gateway provisioned in the hub. Defaults to `false` for the standalone topology.')
param hubIntegrationPeeringUseRemoteGateways bool = false

@description('Deploy an Azure Cognitive Search service for indexing and querying content. When disabled, search-related connections are skipped and search app configuration values resolve to empty values.')
param deploySearchService bool = true

@description('Deploy an Azure AI Speech (SpeechServices) cognitive account with the same private-endpoint / DNS / RBAC posture as the rest of the AI services in this landing zone. Off by default so the change is non-breaking for existing consumers. When enabled under network isolation, the account is created with publicNetworkAccess=Disabled and a private endpoint into the existing privatelink.cognitiveservices.azure.com zone.')
param deploySpeechService bool = false

@description('SKU for the Azure AI Speech service. Only F0 (free) and S0 (standard) are supported via SDK.')
@allowed([
  'F0'
  'S0'
])
param speechServiceSku string = 'S0'

@description('Deploy an Azure AI Document Intelligence (FormRecognizer) account. Off by default. When enabled under network isolation a private endpoint is created reusing the existing privatelink.cognitiveservices.azure.com zone.')
param deployDocumentIntelligence bool = false

@description('SKU for the Document Intelligence account.')
@allowed([
  'F0'
  'S0'
])
param documentIntelligenceSku string = 'S0'

@description('Deploy an Azure Storage Account to hold blobs, queues, tables, and files.')
param deployStorageAccount bool = true

@description('Deploy an Azure Cosmos DB account for globally distributed NoSQL data storage.')
param deployCosmosDb bool = true

@description('Deploy Azure Container Apps for running your microservices in a serverless Kubernetes environment.')
param deployContainerApps bool = true

@description('Deploy an Azure Container Registry to store and manage Docker container images.')
param deployContainerRegistry bool = true

@description('Deploy the Container Apps environment (log ingestion, VNet integration, etc.).')
param deployContainerEnv bool = true

// ---------------------------------------------------------------------------
// Hub-component deployment flags (Gap 4, issue #58)
// ---------------------------------------------------------------------------
// `deployVM` (v1.x) consolidated three independent deployments — jumpbox,
// Bastion, and NAT Gateway — under one switch. v2.0.0 splits them so each
// component can be controlled, reused (BYO) or skipped independently.
//
// Defaults are nullable. When null, the effective value is derived to match
// v1.x behavior (everything deploys when `networkIsolation=true`). Set any
// flag explicitly to override.
//
//   deployJumpbox      | jumpbox VM + CSE + RBAC + (optionally) VM Key Vault
//   deployBastion      | spoke-side Azure Bastion + Bastion NSG + Bastion PIP
//   deployNatGateway   | spoke NAT Gateway + NAT PIP for outbound egress
//
// Each component also accepts a matching `existing<Component>ResourceId` BYO
// parameter. When the BYO ID is non-empty, the corresponding `deploy*` flag
// defaults to `false` and the existing resource ID is consumed by downstream
// wiring (RBAC, diagnostics, runbook docs).
//
@description('Deploy the jumpbox Virtual Machine (and its CSE + RBAC + optional VM Key Vault). When null, defaults to `networkIsolation` to match v1.x behavior. Set to `false` for AI LZ-integrated topologies where the operator connects via central tooling.')
param deployJumpbox bool?

@description('Deploy a spoke-side Azure Bastion + Bastion NSG + Bastion PIP. When null, defaults to `networkIsolation && deployJumpbox` (preserves v1.x behavior). Set to `false` when reusing a central hub Bastion via VNet peering (Gap 7).')
param deployBastion bool?

@description('Deploy a NAT Gateway + NAT PIP for outbound spoke egress. When null, defaults to `networkIsolation && deployJumpbox` (preserves v1.x behavior). Set to `false` when egress is centralized via Azure Firewall in the hub (Gap 6).')
param deployNatGateway bool?

@description('Resource ID of an existing Bastion to reuse (BYO). Informational — used by docs/runbooks. When non-empty, `deployBastion` defaults to `false`.')
param existingBastionResourceId string?

@description('Resource ID of an existing NAT Gateway to associate with the spoke subnets (BYO). When non-empty, `deployNatGateway` defaults to `false`.')
param existingNatGatewayResourceId string?

@description('Resource ID of an existing jumpbox VM (BYO). Informational — used by docs/runbooks for post-provision flows. When non-empty, `deployJumpbox` defaults to `false`.')
param existingJumpboxResourceId string?

@description('DEPRECATED (v2.0.0). Legacy v1.x consolidated switch for jumpbox + Bastion + NAT Gateway. Provided as a transitional fallback so v1.x parameter files continue to deploy unmodified — explicit `deployJumpbox` / `deployBastion` / `deployNatGateway` values ALWAYS take precedence over this flag. Will be REMOVED in v3.0.0; migrate to the three component-specific flags.')
param deployVM bool?

@description('Deploy the virtual network subnets.')
param deploySubnets bool = true

@description('Will deploy network security groups.')
param deployNsgs bool = true

@description('Deploy Azure Firewall with UDR for egress traffic control. Defaults to true when networkIsolation is enabled.')
param deployAzureFirewall bool = true

@description('Deploy an ACR Task agent pool so image builds can run inside the VNet when the registry has public access disabled. Requires a Premium container registry (auto-selected when networkIsolation is true) and is gated on both deployContainerRegistry and networkIsolation.')
param deployAcrTaskAgentPool bool = true

@description('Name for the ACR Task agent pool. Max 20 characters.')
@maxLength(20)
param acrTaskAgentPoolName string = 'build-pool'

@description('SKU tier for the ACR Task agent pool: S1 (2 vCPU), S2 (4 vCPU), S3 (8 vCPU).')
@allowed([ 'S1', 'S2', 'S3' ])
param acrTaskAgentPoolTier string = 'S1'

@description('Initial instance count for the ACR Task agent pool. Set to 0 after provisioning to pause billing (az acr agentpool update -r <acr> -n <pool> --count 0).')
@minValue(0)
param acrTaskAgentPoolCount int = 1

@description('When true, extends the Azure Firewall Policy with the FQDN allow-list required by the default install.ps1 jumpbox bootstrap (Chocolatey, Python, Node, VS Code, GitHub clones, Azure CLI control plane). Disable if you manage egress centrally.')
param extendFirewallForJumpboxBootstrap bool = true

@description('When true, extends the Azure Firewall Policy with the FQDN allow-list required for ACR Tasks builds running inside the build-agents subnet to fetch language packages (npm, PyPI) and OS packages (Debian/Ubuntu apt repos, yarn). Only effective when networkIsolation, deployAzureFirewall and deployAcrTaskAgentPool are all enabled. Disable if you manage egress centrally or pre-bake all dependencies into the builder base image.')
param extendFirewallForAcrTaskBuilds bool = true

@description('Additional FQDNs to allow from the ACR Tasks build-agent subnet when extendFirewallForAcrTaskBuilds is true. Use this for application-specific build dependencies that are not part of the landing-zone default allow-list.')
param additionalAcrTaskBuildFqdns array = []

@description('List of trusted source IP CIDRs allowed to connect to the Bastion public IP on port 443. When empty, all internet inbound to port 443 is denied by default.')
param bastionAllowedSourceIPs array = []

@description('Bastion SKU. `Standard` supports native client (`az network bastion rdp/ssh`) and tunneling; `Premium` adds shareable link, session recording, and private-only mode. `Basic` does not support tunneling.')
@allowed(['Basic', 'Standard', 'Premium'])
param bastionSkuName string = 'Standard'

@description('Enable Bastion native client tunneling. Required for `az network bastion rdp/ssh`, RDP audio/clipboard/device redirection, and SSH agent forwarding. Off by default for parity with portal-only access. Requires `bastionSkuName` to be `Standard` or `Premium`.')
param bastionEnableTunneling bool = false

@description('When true, extends the Azure Firewall Policy with a Network Rule Collection allowing UDP/TCP egress from spoke subnets (jumpbox, ACA environment, agent) to the `AzureCloud` Service Tag. Required for any spoke workload that uses Azure Speech real-time avatar, Azure Communication Services Calling, or Microsoft Teams Media (WebRTC peer connections, STUN/TURN UDP 3478-3481 and TCP 443/3478-3481). Off by default to preserve least-privilege egress. Only effective when `networkIsolation` and `deployAzureFirewall` are both true.')
param enableAcsMediaEgress bool = false

// ----------------------------------------------------------------------
// Public Ingress (#49) — optional Application Gateway WAF v2 in front of the
// internal Container Apps environment. Default-disabled. WARNING: enabling
// this deploys WAF_v2 + a Standard Public IP, which incur hourly charges
// even when idle. To remove the stack, run `azd down` or delete the
// resources manually — `azd`/ARM incremental deployments will NOT delete
// these resources when `publicIngress.enabled` flips back to false after a
// previous deploy. See README "Optional Public Ingress" for the runbook.
// ----------------------------------------------------------------------

@export()
@description('Aggregate parameter for the optional public ingress (Application Gateway WAF v2). See README "Optional Public Ingress".')
type publicIngressType = {
  @description('Master toggle. When false (default) no public-ingress resources are deployed.')
  enabled: bool

  @description('Optional. Index of the entry in `containerAppsList` that the gateway routes to. Defaults to 0.')
  backendAppIndex: int?

  @description('Optional. Frontend host name presented to clients (e.g., app.contoso.com). Required to activate the HTTPS listener.')
  frontendHostName: string?

  @description('Optional. Versionless Key Vault secret ID for the TLS certificate. Required to activate the HTTPS listener.')
  sslCertSecretId: string?

  @description('Optional. CIDRs allowed to reach the gateway on TCP/443. Empty list keeps the gateway fully inert (skeleton mode).')
  allowedSourceAddressPrefixes: string[]?

  @description('Optional. WAF mode. Defaults to `Prevention`.')
  wafMode: ('Prevention' | 'Detection')?

  @description('Optional. WAF custom rules merged with the OWASP CRS 3.2 managed ruleset.')
  wafCustomRules: object[]?

  @description('Optional. AGW autoscale capacity (e.g., `{ minCapacity: 0, maxCapacity: 2 }`).')
  capacity: object?

  @description('Optional. AGW sslPolicy block. When omitted, the gateway uses the Azure default policy.')
  sslPolicy: object?
}

@description('Optional. Public Application Gateway WAF v2 ingress in front of the internal Container Apps environment. Disabled by default. WARNING: enabling this deploys WAF_v2 and a Standard Public IP, which incur hourly charges even when idle. See README "Optional Public Ingress" for the post-deploy runbook.')
param publicIngress publicIngressType = { enabled: false }

@description('Will deploy network resources side by side with the Azure resources.')
param sideBySideDeploy bool = true

@description('Deploy Virtual Machine software.')
param deploySoftware bool = true

@description('Deploy AI Foundry Project.')
param deployAfProject bool = true

@description('Deploy AI Foundry Service.')
param deployAAfAgentSvc bool = true


@description('Enable agentic retrieval features in Azure AI Search indexes. Requires vectorizer configuration and semantic search.')
param enableAgenticRetrieval bool = false

// ----------------------------------------------------------------------
// Reuse Existing Services Parameters
// Note: Reuse is optional. Leave empty to create new resources
// ----------------------------------------------------------------------

// AI Foundry Dependencies

@description('The AI Search Service full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiSearchResourceId string = ''

@description('The AI Storage Account full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiFoundryStorageAccountResourceId string = ''

@description('The SKU name for the AI Foundry Storage Account. Only used when a new account is created (aiFoundryStorageAccountResourceId is empty). The AVM ai-foundry module does not expose this, so we pre-create the storage account with the requested SKU. Defaults to Standard_LRS for broad regional availability (some regions, e.g. Poland Central, do not support the AVM default Standard_GRS).')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param aiFoundryStorageSku string = 'Standard_LRS'

@description('The Cosmos DB account full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiFoundryCosmosDBAccountResourceId string = ''

// GenAI App Services

@description('The Key Vault full ARM resource ID. Optional; if not provided, a new vault will be created.')
param keyVaultResourceId string = ''

// ----------------------------------------------------------------------
// Feature-flagging Params (as booleans with a default of false)
// ----------------------------------------------------------------------
param useUAI bool = false // Use User Assigned Identity (UAI)
param useCAppAPIKey bool = false // Use API Keys to connect to container apps
param useZoneRedundancy bool = false // Use Zone Redundancy

// ----------------------------------------------------------------------
// Resource Naming params
// ----------------------------------------------------------------------

@description('Unique token used to build deterministic resource names, derived from subscription ID, environment name, and location.')
param resourceToken string = toLower(uniqueString(subscription().id, environmentName, location))

@description('Name of the Azure AI Foundry account to create or reference.')
param aiFoundryAccountName string = '${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the AI Foundry project resource.')
param aiFoundryProjectName string = '${const.abbrs.ai.aiFoundryProject}${resourceToken}'

@description('Name of the Storage Account used by AI Foundry for blobs, queues, tables, and files.')
param aiFoundryStorageAccountName string = replace('${const.abbrs.storage.storageAccount}${const.abbrs.ai.aiFoundry}${resourceToken}', '-', '')

@description('Name of the Cognitive Search service provisioned for AI Foundry.')
param aiFoundrySearchServiceName string = '${const.abbrs.ai.aiSearch}${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the Azure Cosmos DB account used by AI Foundry.')
param aiFoundryCosmosDbName string = '${const.abbrs.databases.cosmosDBDatabase}${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the Bing Search resource for grounding capabilities.')
param bingSearchName string = '${const.abbrs.ai.bing}${resourceToken}'

@description('Name of the Azure App Configuration store for centralized settings.')
param appConfigName string = '${const.abbrs.configuration.appConfiguration}${resourceToken}'

@description('Name of the Application Insights instance for monitoring.')
param appInsightsName string = '${const.abbrs.managementGovernance.applicationInsights}${resourceToken}'

@description('Name of the Azure Container Apps environment (log ingestion, VNet integration, etc.).')
param containerEnvName string = '${const.abbrs.containers.containerAppsEnvironment}${resourceToken}'

@description('Name of the Azure Container Registry for storing Docker images.')
param containerRegistryName string = '${const.abbrs.containers.containerRegistry}${resourceToken}'

@description('Name of the Cosmos DB account (alias for database operations).')
param dbAccountName string = '${const.abbrs.databases.cosmosDBDatabase}${resourceToken}'

@description('Name of the Cosmos DB database to host application data.')
param dbDatabaseName string = '${const.abbrs.databases.cosmosDBDatabase}db${resourceToken}'

@description('Name of the Azure Key Vault for secrets, keys, and certificates.')
param keyVaultName string = '${const.abbrs.security.keyVault}${resourceToken}'

@description('Name of the Log Analytics workspace for collecting and querying logs.')
param logAnalyticsWorkspaceName string = '${const.abbrs.managementGovernance.logAnalyticsWorkspace}${resourceToken}'

@description('Name of the Cognitive Search service.')
param searchServiceName string = '${const.abbrs.ai.aiSearch}${resourceToken}'

@description('Optional override for the Azure AI Speech account name. When empty, a name is generated from the resource token. Also used as the customSubDomainName, so it must be globally unique within `cognitiveservices.azure.com`.')
param speechServiceName string = '${const.abbrs.ai.speechService}${resourceToken}'

@description('Azure region for Document Intelligence. Must be one of eastus, westus2, westeurope (FormRecognizer availability constraint).')
@allowed(['eastus', 'westus2', 'westeurope'])
param documentIntelligenceLocation string = 'eastus'

@description('Optional override for the Document Intelligence account name. When empty, a name is generated. Also used as customSubDomainName.')
param documentIntelligenceName string = 'docintel-${resourceToken}'

@description('Name of the Azure Storage Account for general-purpose blob and file storage.')
param storageAccountName string = '${const.abbrs.storage.storageAccount}${resourceToken}'

@description('Name of the Virtual Network to isolate resources and enable private endpoints.')
param vnetName string = '${const.abbrs.networking.virtualNetwork}${resourceToken}'

// ----------------------------------------------------------------------
// Azure AI Foundry Service params
// ----------------------------------------------------------------------

@description('List of model deployments to create in the AI Foundry account')
param modelDeploymentList array

// ----------------------------------------------------------------------
// Container Apps params
// ----------------------------------------------------------------------

@description('List of container apps to create')
param containerAppsList array

@description('Workload profiles.')
param workloadProfiles array = []

param acrDnsSuffix string = (environment().name == 'AzureUSGovernment' ? 'azurecr.us' : environment().name == 'AzureChinaCloud'   ? 'azurecr.cn' : 'azurecr.io')

// ----------------------------------------------------------------------
// Cosmos DB Database params
// ----------------------------------------------------------------------

@description('Optional throughput (RU/s) for the Cosmos DB database. Omit or set to null for serverless accounts.')
param dbDatabaseThroughput int?

@description('List of Cosmos DB containers to create. Each entry supports optional throughput and indexingPolicy via safe access.')
param databaseContainersList array

@description('Enable Synapse Link / Analytical Storage on the workload Cosmos DB account. Default is false because (a) Azure currently restricts enabling this on account creation in several region/subscription combinations and breaks provisioning, and (b) the default landing-zone topology does not deploy any Analytical Store consumer (Synapse Link, Fabric Mirroring). Set to true only when a downstream pipeline actively consumes the analytical store and the target region/subscription is known to allow it. Note: Azure does not permit toggling this flag on an existing Cosmos DB account; the value only takes effect at account creation.')
param enableCosmosAnalyticalStorage bool = false

// ----------------------------------------------------------------------
// VM params
// ----------------------------------------------------------------------

@description('The name of the Test VM. If left empty, a random name will be generated.')
param vmName string = ''

@description('Test vm user name. Needed only when choosing network isolation and create bastion option. If not you can leave it blank.')
param vmUserName string = ''

@secure()
@description('Admin password for the test VM user')
param vmAdminPassword string

@description('Size of the test VM')
param vmSize string = 'Standard_D2s_v5'

@description('Image SKU (e.g., 2022-datacenter-azure-edition, win11-25h2-ent).')
param vmImageSku string = '2022-datacenter-azure-edition'

@description('Image publisher (Windows Server: MicrosoftWindowsServer, Windows 11: MicrosoftWindowsDesktop).')
param vmImagePublisher string = 'MicrosoftWindowsServer'

@description('Image offer (Windows Server: WindowsServer, Windows 11: windows-11).')
param vmImageOffer string = 'WindowsServer'

@description('Image version (use latest unless you need a pinned build).')
param vmImageVersion string = 'latest'


// ----------------------------------------------------------------------
// Storage Account params
// ----------------------------------------------------------------------

@description('List of containers to create in the Storage Account')
param storageAccountContainersList array

// ----------------------------------------------------------------------
// CMK params
// ----------------------------------------------------------------------
// Note : Customer Managed Keys (CMK) not implemented in this module yet
// @description('Use Customer Managed Keys for Storage Account and Key Vault')
// param useCMK      bool   = false

//////////////////////////////////////////////////////////////////////////
// VARIABLES
//////////////////////////////////////////////////////////////////////////

// ----------------------------------------------------------------------
// General Variables
// ----------------------------------------------------------------------

var _manifest = loadJsonContent('./manifest.json')
var _azdTags = { 'azd-env-name': environmentName }
var _modeTags = { deploymentMode: deploymentMode, 'ai-lz-version': 'v2.0.0' }
var _tags = union(_azdTags, _modeTags, deploymentTags)

// Derive the list of additional Git repositories to clone onto the jumpbox
// directly from `manifest.json#components`. Consumers that use this landing
// zone as a Bicep module / git submodule overlay their own `manifest.json`
// (the documented submodule pattern) and so control the components there as
// the single source of truth, without needing per-deployment Bicep params.
// The derived CSV strings are forwarded to install.ps1 via the CSE
// commandToExecute as `-ExtraRepoUrls/-ExtraRepoTags/-ExtraRepoNames`. See
// issue #22.
var _manifestComponents = _manifest.?components ?? []
var _extraRepoUrls  = [for c in _manifestComponents: c.repo]
var _extraRepoTags  = [for c in _manifestComponents: c.?tag ?? 'main']
var _extraRepoNames = [for c in _manifestComponents: c.?name ?? replace(last(split(c.repo, '/')), '.git', '')]

var _networkIsolation = empty(string(networkIsolation)) ? false : bool(networkIsolation)

// -----------------------------------------------------------------------------
// Public network access derivation (Gap 1, issue #58)
// -----------------------------------------------------------------------------
// `publicNetworkAccess` for every workload service is now derived from two
// flat inputs rather than coupled directly to `_networkIsolation`:
//
//   _applyIpRules:        true when the operator provided one or more CIDRs.
//   _publicNetworkAccess: 'Enabled' when the topology is public OR an
//                         IP allow-list is in effect; otherwise 'Disabled'.
//
// Two parameters cover all four scenarios documented in issue #58:
//
//   networkIsolation=true,  allowedIpRanges=[]      -> Private only
//   networkIsolation=true,  allowedIpRanges=[CIDR]  -> Private + public allow-list
//   networkIsolation=false, allowedIpRanges=[]      -> Public
//   networkIsolation=false, allowedIpRanges=[CIDR]  -> Public restricted to listed IPs
//
// Per-service rule arrays are pre-shaped because each Azure RP exposes a
// slightly different schema (Storage/ACR use `{value, action}`, KV/Search/
// Cognitive use `{value}`, Cosmos accepts a flat string[]).
var _applyIpRules        = !empty(allowedIpRanges)
var _publicNetworkAccess = (!_networkIsolation || _applyIpRules) ? 'Enabled' : 'Disabled'
var _storageIpRules      = [for ip in allowedIpRanges: { value: ip, action: 'Allow' }]
var _acrIpRules          = [for ip in allowedIpRanges: { value: ip, action: 'Allow' }]
var _keyVaultIpRules     = [for ip in allowedIpRanges: { value: ip }]
var _searchIpRules       = [for ip in allowedIpRanges: { value: ip }]
var _cognitiveIpRules    = [for ip in allowedIpRanges: { value: ip }]
var _cosmosIpRules       = allowedIpRanges
// ---------------------------------------------------------------------------
// Hub-component effective deployment derivations (Gap 4, issue #58)
// ---------------------------------------------------------------------------
// Nullable inputs coalesce to v1.x defaults so existing parameter files
// (without the new flags) behave identically. BYO resource IDs flip the
// default to `false` automatically — explicit `true/false` always wins.
var _hasExistingJumpbox     = !empty(existingJumpboxResourceId ?? '')
var _hasExistingBastion     = !empty(existingBastionResourceId ?? '')
var _hasExistingNatGateway  = !empty(existingNatGatewayResourceId ?? '')

// Legacy fallback (v1.x compatibility): when `deployVM` is non-null, it acts
// as a global default for all three new flags so existing parameter files
// (e.g. GPT-RAG's manifest-driven overlay) keep working unmodified. Explicit
// new flags ALWAYS win — `deployVM` is purely a fallback layer. Slated for
// removal in v3.0.0; emits a deployment-time warning when consumed.
var _legacyDeployVMSet      = !(deployVM == null)
#disable-next-line BCP318
var _legacyDeployVMValue    = _legacyDeployVMSet ? deployVM! : false
var _deployJumpbox          = deployJumpbox    ?? (_legacyDeployVMSet ? (_legacyDeployVMValue && _networkIsolation && !_hasExistingJumpbox)    : (_networkIsolation && !_hasExistingJumpbox))
var _deployBastion          = deployBastion    ?? (_legacyDeployVMSet ? (_legacyDeployVMValue && _networkIsolation && _deployJumpbox && !_hasExistingBastion)    : (_networkIsolation && _deployJumpbox && !_hasExistingBastion))
var _deployNatGateway       = deployNatGateway ?? (_legacyDeployVMSet ? (_legacyDeployVMValue && _networkIsolation && _deployJumpbox && !_hasExistingNatGateway) : (_networkIsolation && _deployJumpbox && !_hasExistingNatGateway))

// Effective NAT Gateway ID — when we deploy our own NAT GW, use that. When
// the operator BYO'd one, use theirs. Otherwise empty (subnet leaves
// natGateway unset). Wired into `baseSubnets[jumpbox].natGatewayResourceId`
// so both code paths (greenfield + useExistingVNet) attach the subnet
// to the NAT GW.
#disable-next-line BCP318
var _effectiveNatGatewayId  = _deployNatGateway ? natGateway.id : (_hasExistingNatGateway ? existingNatGatewayResourceId! : '')

// ---------------------------------------------------------------------------
// Observability reuse derivations (Gap 5, issue #58)
// ---------------------------------------------------------------------------
// When the operator supplies an existing LAW or AppInsights resource ID, we
// SKIP creating those resources locally and route every consumer — diagnostic
// settings, AMPLS, Container Apps Environment telemetry, App Configuration
// publishing — to the existing IDs instead.
//
//   _hasExistingLaw / _hasExistingAI  : BYO ID provided?
//   _createLogAnalytics / _createAppInsights : do we deploy our own?
//   _lawResourceId / _appInsightsResourceId  : effective IDs to wire downstream
//   _appInsightsConnectionString             : effective connection string for
//                                              Container Apps + App Config
//
// Cross-RG-safe: we never call `.id` / `.properties` against `existing`
// resources here — those are passed through unchanged as raw strings.
var _hasExistingLaw           = !empty(existingLogAnalyticsWorkspaceResourceId ?? '')
var _hasExistingAI            = !empty(existingApplicationInsightsResourceId ?? '')
var _createLogAnalytics       = deployLogAnalytics && !_hasExistingLaw
var _createAppInsights        = deployAppInsights && !_hasExistingAI && (_createLogAnalytics || _hasExistingLaw)
#disable-next-line BCP318
var _lawResourceId            = _hasExistingLaw ? existingLogAnalyticsWorkspaceResourceId! : (_createLogAnalytics ? logAnalytics.id : '')
#disable-next-line BCP318
var _appInsightsResourceId    = _hasExistingAI ? existingApplicationInsightsResourceId! : (_createAppInsights ? appInsights.id : '')
#disable-next-line BCP318
var _appInsightsConnectionString = _hasExistingAI ? (existingApplicationInsightsConnectionString ?? '') : (_createAppInsights ? appInsights.properties.ConnectionString : '')
// Instrumentation key is the first KV pair in a v2 connection string
// ("InstrumentationKey=<guid>;..."). We split safely so an empty string
// returns an empty key rather than failing the template.
var _appInsightsInstrumentationKey = !empty(_appInsightsConnectionString)
  ? split(split(_appInsightsConnectionString, ';')[0], '=')[1]
  : ''
var _hasEffectiveLaw          = !empty(_lawResourceId)
var _hasEffectiveAI           = !empty(_appInsightsResourceId)

// ----------------------------------------------------------------------
// Gap 6 — External egress / route table reuse
// ----------------------------------------------------------------------
// Three valid configurations are now supported for the spoke 0.0.0.0/0 default route:
//   1. Standalone (deployAzureFirewall=true)                : local FW, local RT, route → local FW IP.
//   2. AI-LZ-integrated, hub-FW shared                       : deployAzureFirewall=false +
//                                                             hubIntegrationEgressNextHopIp set → local RT,
//                                                             route → hub FW IP.
//   3. AI-LZ-integrated, platform-team-owned RT              : hubIntegrationExistingRouteTableResourceId set →
//                                                             no local RT, no local default route. The
//                                                             platform team's RT is attached to spoke subnets
//                                                             and is assumed to already define egress routing.
// Any other combination is invalid and surfaced by the pre-flight script (Gap 9).
var _hasExistingRouteTable = !empty(hubIntegrationExistingRouteTableResourceId ?? '')
var _hasExternalEgress     = !empty(hubIntegrationEgressNextHopIp ?? '')
var _createRouteTable      = _networkIsolation && !_hasExistingRouteTable
#disable-next-line BCP318
var _effectiveRouteTableId = _hasExistingRouteTable
  ? hubIntegrationExistingRouteTableResourceId!
  : (_createRouteTable ? routeTable.id : '')
var _createDefaultRoute    = _createRouteTable && (deployAzureFirewall || _hasExternalEgress)
#disable-next-line BCP318
var _defaultRouteNextHopIp = deployAzureFirewall
  ? (_networkIsolation ? azureFirewall!.properties.ipConfigurations[0].properties.privateIPAddress : '')
  : (_hasExternalEgress ? hubIntegrationEgressNextHopIp! : '')

// ----------------------------------------------------------------------
// Gap 7 — Hub VNet peering (spoke side)
// ----------------------------------------------------------------------
// Spoke→hub peering is created inline when the spoke owns its VNet
// (useExistingVNet=false) and the operator opts in. The hub VNet may
// reside in a different subscription/RG; we parse its segments so the
// peering resource (which lives under the spoke VNet) can reference
// the remote VNet correctly. The reverse hub→spoke peering is the
// operator's responsibility — see tests/scripts/Add-HubSpokePeering.ps1.
var _hasHubVnet      = !empty(hubIntegrationHubVnetResourceId ?? '')
var _createSpokeToHubPeering = _hasHubVnet && hubIntegrationCreateHubPeering && _networkIsolation && !useExistingVNet
var _hubVnetSegs   = _hasHubVnet ? split(hubIntegrationHubVnetResourceId!, '/') : ['']
var _hubVnetName   = length(_hubVnetSegs) >= 9 ? _hubVnetSegs[8] : ''

// AMPLS (Azure Monitor Private Link Scope) and the related monitor/opinsights/automation
// private DNS zones + private endpoint are only deployed when network isolation is on AND
// the operator explicitly opts in via enablePrivateLogAnalytics AND we're creating our
// own LAW locally (a BYO/central LAW is assumed to be private-linked centrally already,
// so deploying a duplicate AMPLS would conflict on the shared monitor private DNS zones).
var _deployAmpls = _networkIsolation && _createAppInsights && _createLogAnalytics && enablePrivateLogAnalytics
var _deployPrivateDnsZones = _networkIsolation && !policyManagedPrivateDns
var _searchServiceLocation = empty(searchServiceLocation) ? location : searchServiceLocation
var _speechServiceLocation = empty(speechServiceLocation) ? location : speechServiceLocation
var _documentIntelligenceLocation = documentIntelligenceLocation


// ----------------------------------------------------------------------
// Container vars
// ----------------------------------------------------------------------

// Placeholder image deployed initially; replaced by the operator's real image
// via `azd deploy`. Pinned to `aspnetapp-9.0` because:
//   - it listens on port 8080 by default (matches our `target_port` default,
//     so the placeholder serves a working page out of the box and lets the
//     operator validate ingress before deploying their app);
//   - it is published on MCR (no auth required from ACA pull egress);
//   - the explicit tag prevents drift when Microsoft retags `:aspnetapp`.
var _containerDummyImageName = 'mcr.microsoft.com/dotnet/samples:aspnetapp-9.0'

// ----------------------------------------------------------------------
// Networking vars
// ----------------------------------------------------------------------

// Parse existing VNet Resource ID if provided
var varVnetIdSegments = empty(existingVnetResourceId) ? [''] : split(existingVnetResourceId, '/')
var varExistingVnetSubscriptionId = length(varVnetIdSegments) >= 3 ? varVnetIdSegments[2] : subscription().subscriptionId
var varExistingVnetResourceGroupName = length(varVnetIdSegments) >= 5 ? varVnetIdSegments[4] : resourceGroup().name
var varExistingVnetName = length(varVnetIdSegments) >= 9 ? varVnetIdSegments[8] : ''

var virtualNetworkResourceId = _networkIsolation ? (useExistingVNet ? existingVnetResourceId : virtualNetwork!.outputs.resourceId) : ''

#disable-next-line BCP318
var _peSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${peSubnetName}' : ''
#disable-next-line BCP318
var _caEnvSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${acaEnvironmentSubnetName}' : ''
#disable-next-line BCP318
var _jumpbxSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${jumpboxSubnetName}' : ''
#disable-next-line BCP318
var _agentSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${agentSubnetName}' : ''

var _peLocation = !empty(privateEndpointLocation) ? privateEndpointLocation : location
var _defaultPeResourceGroupName = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _peResourceGroupName = !empty(privateEndpointResourceGroupName) ? privateEndpointResourceGroupName : _defaultPeResourceGroupName

// ----------------------------------------------------------------------
// VM vars
// ----------------------------------------------------------------------

var _vmBaseName = !empty(vmName) ? vmName : 'testvm${resourceToken}'
var _vmName = substring(_vmBaseName, 0, 15)
var _vmUserName = !empty(vmUserName) ? vmUserName : 'testvmuser'

// ----------------------------------------------------------------------
// Container App vars
// ----------------------------------------------------------------------

var _containerAppsKeyVaultKeysTemp =  [
  for app in containerAppsList: {
    name: '${app.canonical_name}_APIKEY'
    value: resourceToken
    contentType: 'string'
  }
]
var _containerAppsKeyVaultKeys = _useCAppAPIKey ? _containerAppsKeyVaultKeysTemp : []

// ----------------------------------------------------------------------
// // Feature-flagging vars 
// ----------------------------------------------------------------------
var _useUAI         = empty(string(useUAI)) ? false : bool(useUAI)
var _useCAppAPIKey  = empty(string(useCAppAPIKey))? false : bool(useCAppAPIKey)

//////////////////////////////////////////////////////////////////////////
// RESOURCES
//////////////////////////////////////////////////////////////////////////

// Security
///////////////////////////////////////////////////////////////////////////

// Network Watcher
// Note: Automatically provisioned when network isolation is enabled (VNet deployment)

// Azure Defender for Cloud
// Note: By default, free tier (foundational recommendations) is enabled at the subscription level.
//       To enable its advanced threat protection features, Defender plans must be explicitly configured
//       using the Microsoft.Security/pricings resource (e.g., for Storage, Key Vault, App Services).

// Purview Compliance Manager
// Note: Not applicable, it's part of Microsoft 365 Compliance Center, not Azure Resource Manager.

// Networking
///////////////////////////////////////////////////////////////////////////

// Bastion NSG — restricts inbound 443 to trusted IPs only
module bastionNsg 'modules/networking/bastion-nsg.bicep' = if (_deployBastion && deployNsgs) {
  name: 'bastionNsgDeployment'
  params: {
    name: 'nsg-${vnetName}-${azureBastionSubnetName}'
    location: location
    bastionAllowedSourceIPs: bastionAllowedSourceIPs
  }
}

// Public Ingress NSG (#49) — declared in main.bicep because the Application
// Gateway subnet's `networkSecurityGroupResourceId` must be set in the same
// subnet declaration that creates the subnet. Splitting NSG creation out of
// the public-ingress module avoids a circular dependency between the subnet
// and the gateway.
module appGwNsg 'modules/networking/appgw-nsg.bicep' = if (_publicIngressEnabled) {
  name: 'appGwNsgDeployment'
  params: {
    name: 'nsg-${vnetName}-${azureAppGatewaySubnetName}'
    location: location
    allowedSourceAddressPrefixes: _publicIngressAllowedSources
  }
}

// Firewall FQDN allowlist for essential outbound connectivity
// Essential (shared across subnets, source = '*'): auth, container registry mirror, GitHub
var _firewallEssentialAuthFqdns = [
  #disable-next-line no-hardcoded-env-urls
  'login.microsoftonline.com'
  'login.windows.net'
  #disable-next-line no-hardcoded-env-urls
  'management.azure.com'
  'graph.microsoft.com'
  '*.applicationinsights.azure.com'
]
var _firewallEssentialContainerFqdns = ['mcr.microsoft.com', '*.data.mcr.microsoft.com']
// Platform-internal FQDNs required by the Container Apps Environment itself when egress
// is forced through Azure Firewall (fixes #39, #40). The per-pod IMDS sidecar that backs
// IDENTITY_ENDPOINT / IDENTITY_HEADER has two independent legs that both need to traverse
// the firewall: (a) a Microsoft-managed Service Bus / Event Hub namespace whose FQDN
// matches `gsm*eh.servicebus.windows.net` (the broker leg, fixes #39); (b) the ACA token
// endpoint at `control-{region}.identity.azure.net` (the token-endpoint leg, fixes #40).
// Without BOTH allow rules, every DefaultAzureCredential / ManagedIdentityCredential call
// from a Container App fails at runtime with HTTP 500 "An unexpected error occured while
// fetching the AAD Token", with no log entry on the workload side indicating the firewall
// is the cause. Also includes ACA control-plane and Azure Monitor / Log Analytics /
// Application Insights ingestion endpoints used by the platform's diagnostics pipeline.
// Azure Firewall application-rule wildcards only match a single label, so explicit
// wildcarded FQDNs are required (a generic `*.windows.net` does NOT match
// `gsm123eh.servicebus.windows.net`, and `*.azure.com` does NOT match
// `control-swedencentral.identity.azure.net`).
var _firewallEssentialPlatformFqdns = [
  '*.servicebus.windows.net'
  '*.identity.azure.net'
  '*.azurecontainerapps.io'
  '*.azurecontainerapps.dev'
  '*.in.applicationinsights.azure.com'
  '*.livediagnostics.monitor.azure.com'
  '*.ingest.monitor.azure.com'
  '*.monitor.azure.com'
  '*.monitor.core.windows.net'
  '*.opinsights.azure.com'
  '*.loganalytics.io'
  // Certificate revocation / trust list (Schannel + .NET) — fixes #42.
  // Without these, Windows TLS clients (Bastion/jumpbox curl.exe, Invoke-WebRequest,
  // .NET HttpClient with CheckCertificateRevocationList=true) fail with
  // CRYPT_E_REVOCATION_OFFLINE when validating Azure-managed certs served by
  // Container Apps / App Service / etc. These are public Microsoft + DigiCert
  // revocation endpoints implicit in any Azure-issued cert chain — allowing them
  // in an outbound rule does not weaken the Zero Trust posture.
  'oneocsp.microsoft.com'
  'ocsp.digicert.com'
  'crl.microsoft.com'
  'crl2.microsoft.com'
  'crl3.microsoft.com'
  'crl.digicert.com'
  'crl3.digicert.com'
  'crl4.digicert.com'
  'ctldl.windowsupdate.com'
]
var _firewallEssentialGitHubFqdns = [
  'github.com'
  '*.github.com'
  'raw.githubusercontent.com'
  'codeload.github.com'
  'objects.githubusercontent.com'
  '*.githubusercontent.com'
]

// Jumpbox-only FQDNs — scoped to jumpboxSubnetPrefix so ACA/agent subnets do not
// inherit developer-tooling egress. Split into purpose-labeled sets so consumers can
// audit which tool requires which endpoint.
// Docker / Docker Hub FQDNs intentionally removed — image builds run in the ACR
// Tasks agent pool (see deployAcrTaskAgentPool) and the Windows Server jumpbox
// cannot build Linux images with BuildKit anyway.
var _firewallVmBootstrapFqdns = [
  'community.chocolatey.org'
  'packages.chocolatey.org'
  '*.chocolatey.org'
  'api.nuget.org'
  'www.nuget.org'
  'dist.nuget.org'
  '*.nuget.org'
  'download.visualstudio.microsoft.com'
  '*.visualstudio.microsoft.com'
  'download.microsoft.com'
  '*.download.microsoft.com'
  'aka.ms'
  'go.microsoft.com'
  // azd auto-downloads the Bicep CLI binary from `downloads.bicep.azure.com`
  // on first run (`azd env refresh` / `azd provision`); without this FQDN the
  // jumpbox fails at "Downloading Bicep" before any deployment work begins
  // (#36).
  'downloads.bicep.azure.com'
  // GitHub release fallback used by azd, the .NET installer, and many
  // bootstrap scripts. `objects.githubusercontent.com` and
  // `codeload.github.com` are the actual content hosts behind release asset
  // and source-archive URLs respectively (#36).
  'github.com'
  '*.githubusercontent.com'
  'objects.githubusercontent.com'
  'codeload.github.com'
  #disable-next-line no-hardcoded-env-urls
  '*.core.windows.net'
  '*.azureedge.net'
]
#disable-next-line no-hardcoded-env-urls
var _firewallDevRuntimeFqdns = [
  'www.python.org'
  '*.python.org'
  'pypi.org'
  '*.pypi.org'
  'files.pythonhosted.org'
  '*.pythonhosted.org'
  // get-pip.py is served from bootstrap.pypa.io. Required by the Python
  // embeddable-distribution install path on the jumpbox (see issue #48 and
  // install.ps1) which downloads `get-pip.py` to bootstrap pip into
  // `C:\Python311` after extracting the embeddable zip.
  'bootstrap.pypa.io'
  '*.pypa.io'
  'registry.npmjs.org'
  '*.npmjs.org'
]
// Jumpbox ACME workflow egress (issue #53): scoped only to the jumpbox subnet
// and only when `extendFirewallForJumpboxBootstrap=true`.
// - api.github.com: reserved for ACME-client release discovery / plugin checks.
// - acme-v02.api.letsencrypt.org: Let's Encrypt ACME v2 directory endpoint
//   used during certificate issuance/renewal.
var _firewallJumpboxAcmeFqdns = [
  'api.github.com'
  'acme-v02.api.letsencrypt.org'
]
#disable-next-line no-hardcoded-env-urls
var _firewallEditorFqdns = [
  'update.code.visualstudio.com'
  '*.vo.msecnd.net'
  '*.vscode-cdn.net'
]

// Azure AI Speech FQDNs (#35) — only added to the bootstrap allow rule when
// `deploySpeechService` is true. Covers control plane, TTS, and STT regional
// endpoints used by the Speech SDK.
#disable-next-line no-hardcoded-env-urls
var _firewallSpeechFqdns = deploySpeechService ? [
  '*.cognitiveservices.azure.com'
  '*.tts.speech.microsoft.com'
  '*.stt.speech.microsoft.com'
] : []

// ACR Tasks agent-pool FQDNs — scoped to devopsBuildAgentsSubnetPrefix. Only
// populated when the agent pool is actually deployed.
//
// Note: ACR Tasks agents need egress to ACR data plane (`*.azurecr.io`,
// `*.data.azurecr.io`) AND to the Azure Storage queue/blob/table endpoints
// the ACR Tasks control plane uses to dispatch jobs to the agent VM.
// Without the *.core.windows.net FQDNs, builds queued via
// `az acr build --agent-pool` hang indefinitely in `Queued` state because
// the agent VM cannot reach the storage queue. See issue #18.
var _deployAcrTaskAgentPool = deployContainerRegistry && _networkIsolation && deployAcrTaskAgentPool

// Public Ingress (#49) — only effective in network-isolated mode with Container
// Apps deployed. The gateway fronts an internal ACA environment, so it is a
// no-op outside that topology.
var _publicIngressEnabled = publicIngress.enabled && _networkIsolation && deployContainerEnv && deployContainerApps && length(containerAppsList) > 0
var _publicIngressBackendIndex = publicIngress.?backendAppIndex ?? 0
var _publicIngressAllowedSources = publicIngress.?allowedSourceAddressPrefixes ?? []
var _firewallAcrTaskFqdns = _deployAcrTaskAgentPool ? [
  '*.azurecr.io'
  '*.data.azurecr.io'
  '*.blob.${environment().suffixes.storage}'
  '*.queue.${environment().suffixes.storage}'
  '*.table.${environment().suffixes.storage}'
] : []

// OS package repositories used by Debian/Ubuntu-based builder images during
// `apt-get` steps in ACR Tasks runs. Scoped to devopsBuildAgentsSubnetPrefix
// via `AllowAcrTaskOsPackages`. Includes packages.microsoft.com because
// Microsoft-supported Linux packages such as msodbcsql18 are common build-time
// dependencies for solution accelerators. Language registries (npm/PyPI/python.org)
// are reused from `_firewallDevRuntimeFqdns` via `AllowAcrTaskDevRuntimes`.
// See issues #20 and #68.
#disable-next-line no-hardcoded-env-urls
var _firewallAcrTaskOsPackageFqdns = [
  'deb.debian.org'
  'security.debian.org'
  'archive.ubuntu.com'
  'security.ubuntu.com'
  'dl.yarnpkg.com'
  'packages.microsoft.com'
]

// Route Table for egress traffic control through Azure Firewall (or external NVA, Gap 6).
// Created only when network isolation is on AND no existing RT is provided via
// `hubIntegrationExistingRouteTableResourceId`.
resource routeTable 'Microsoft.Network/routeTables@2024-07-01' = if (_createRouteTable) {
  name: '${const.abbrs.networking.routeTable}${resourceToken}'
  location: location
  tags: _tags
  properties: {
    disableBgpRoutePropagation: true
  }
}

// Base subnets that are always included
var baseSubnets = [
      {
        name: agentSubnetName
        addressPrefix: agentSubnetPrefix 
        delegation: 'Microsoft.app/environments'
        routeTableResourceId: _effectiveRouteTableId
        serviceEndpoints: [
          'Microsoft.CognitiveServices'
        ]
      }
      {
        name: peSubnetName
        addressPrefix: peSubnetPrefix 
        routeTableResourceId: _effectiveRouteTableId
        serviceEndpoints: [
          'Microsoft.AzureCosmosDB'
        ]        
        delegation: ''
      }
      {
        name: gatewaySubnetName
        addressPrefix: gatewaySubnetPrefix 
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureBastionSubnetName
        addressPrefix: azureBastionSubnetPrefix
        #disable-next-line BCP318
        networkSecurityGroupResourceId: (_deployBastion && deployNsgs) ? bastionNsg!.outputs.id : ''
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureFirewallSubnetName
        addressPrefix: azureFirewallSubnetPrefix 
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureAppGatewaySubnetName
        addressPrefix: azureAppGatewaySubnetPrefix  
        #disable-next-line BCP318
        networkSecurityGroupResourceId: _publicIngressEnabled ? appGwNsg!.outputs.id : ''
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: jumpboxSubnetName
        addressPrefix: jumpboxSubnetPrefix 
        natGatewayResourceId: _effectiveNatGatewayId
        routeTableResourceId: _effectiveRouteTableId
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: acaEnvironmentSubnetName
        addressPrefix: acaEnvironmentSubnetPrefix  
        delegation: 'Microsoft.app/environments'
        routeTableResourceId: _effectiveRouteTableId
        serviceEndpoints: [
          'Microsoft.AzureCosmosDB'
        ]
      }
      {
        name: devopsBuildAgentsSubnetName
        addressPrefix: devopsBuildAgentsSubnetPrefix 
        routeTableResourceId: _effectiveRouteTableId
        delegation: ''
        serviceEndpoints : []
      }
]

var subnets = baseSubnets

module virtualNetworkSubnets 'modules/networking/subnets.bicep' = if (_networkIsolation && useExistingVNet && deploySubnets) {
  name: 'virtualNetworkSubnetsDeployment'
  params: {
    vnetName: useExistingVNet ? varExistingVnetName : vnetName
    location: location
    resourceGroupName: useExistingVNet ? varExistingVnetResourceGroupName : resourceGroup().name
    subscriptionId: useExistingVNet ? varExistingVnetSubscriptionId : subscription().subscriptionId
    tags: _tags
    addressPrefixes: vnetAddressPrefixes
    subnets: subnets
    deploySubnets : deploySubnets
    deployNsgs: deployNsgs
    useExistingVNet: useExistingVNet
    virtualNetworkResourceId: virtualNetworkResourceId
  }
}

// VNet
// Note on IP address sizing: https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/virtual-networks#known-limitations
module virtualNetwork 'br/public:avm/res/network/virtual-network:0.7.0' = if (_networkIsolation && !useExistingVNet) {
  name: 'virtualNetworkDeployment'
  params: {
    // VNet sized /16 to fit all subnets
    addressPrefixes: vnetAddressPrefixes
    name: vnetName
    location: location

    tags: _tags
    subnets: subnets
  }
}

// Gap 7 — Spoke→hub VNet peering.
// Lives under the locally-created spoke VNet; the existing resource
// reference below ensures Bicep can attach the peering as a child without
// the AVM module having to expose a peerings property.
resource spokeVnetForPeering 'Microsoft.Network/virtualNetworks@2024-07-01' existing = if (_createSpokeToHubPeering) {
  name: vnetName
}

resource spokeToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = if (_createSpokeToHubPeering) {
  parent: spokeVnetForPeering
  name: 'to-hub-${_hubVnetName}'
  properties: {
    allowVirtualNetworkAccess: true
    // Required so the hub Azure Firewall (or any hub NVA) can forward spoke
    // traffic on behalf of the spoke. Without this, asymmetric routing
    // through the hub firewall breaks.
    allowForwardedTraffic: true
    allowGatewayTransit: hubIntegrationPeeringAllowGatewayTransit
    useRemoteGateways: hubIntegrationPeeringUseRemoteGateways
    remoteVirtualNetwork: {
      #disable-next-line BCP318
      id: hubIntegrationHubVnetResourceId!
    }
  }
  dependsOn: [
    virtualNetwork
  ]
}

// Bastion Host
// Bastion Host — replaced the AVM `bastion-host` module with a raw resource so
// `enableTunneling` can be set (the AVM module up to 0.8.2 does not expose it).
// Native-client tunneling is required for `az network bastion rdp/ssh`, RDP
// audio/clipboard/device redirection, and SSH agent forwarding from inside the
// spoke. Behavior-equivalent to the previous module call: same subnet
// (AzureBastionSubnet), Standard static PIP, optional zone redundancy, tags.
resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (_deployBastion) {
  name: '${const.abbrs.networking.publicIPAddress}bastion-${resourceToken}'
  location: location
  tags: _tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: useZoneRedundancy ? ['1', '2', '3'] : []
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource testVmBastionHost 'Microsoft.Network/bastionHosts@2024-07-01' = if (_deployBastion) {
  name: '${const.abbrs.security.bastion}testvm-${resourceToken}'
  location: location
  tags: _tags
  sku: {
    name: bastionSkuName
  }
  zones: useZoneRedundancy ? ['1', '2', '3'] : []
  properties: {
    // enableTunneling is silently coerced to false on Basic SKU because the
    // Basic SKU does not support native client tunneling. Standard and Premium
    // accept the value.
    enableTunneling: bastionEnableTunneling && bastionSkuName != 'Basic'
    ipConfigurations: [
      {
        name: 'IpConfAzureBastionSubnet'
        properties: {
          subnet: {
            #disable-next-line BCP318
            id: '${virtualNetworkResourceId}/subnets/AzureBastionSubnet'
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
  dependsOn: [
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

// Azure Firewall for egress traffic control
///////////////////////////////////////////////////////////////////////////

resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  name: '${const.abbrs.networking.publicIPAddress}${const.abbrs.networking.firewall}${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
  tags: _tags
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  name: '${const.abbrs.networking.firewallPolicy}${resourceToken}'
  location: location
  tags: _tags
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
  }
}

resource firewallPolicyDefaultRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  parent: firewallPolicy
  name: 'DefaultRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowEssentialOutbound'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: concat(
          [
            {
              ruleType: 'ApplicationRule'
              name: 'AllowMicrosoftContainerRegistry'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: _firewallEssentialContainerFqdns
              sourceAddresses: ['*']
            }
            {
              ruleType: 'ApplicationRule'
              name: 'AllowEntraIdAuth'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: _firewallEssentialAuthFqdns
              sourceAddresses: ['*']
            }
            {
              ruleType: 'ApplicationRule'
              name: 'AllowGitHub'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: _firewallEssentialGitHubFqdns
              sourceAddresses: ['*']
            }
            {
              ruleType: 'ApplicationRule'
              name: 'AllowContainerAppsPlatform'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: _firewallEssentialPlatformFqdns
              sourceAddresses: ['*']
            }
          ],
          extendFirewallForJumpboxBootstrap ? [
            {
              ruleType: 'ApplicationRule'
              name: 'AllowJumpboxBootstrap'
              protocols: [
                { protocolType: 'Https', port: 443 }
                { protocolType: 'Http', port: 80 }
              ]
              targetFqdns: concat(_firewallVmBootstrapFqdns, _firewallSpeechFqdns)
              sourceAddresses: [jumpboxSubnetPrefix]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'AllowJumpboxDevRuntimes'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: _firewallDevRuntimeFqdns
              sourceAddresses: [jumpboxSubnetPrefix]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'AllowJumpboxEditors'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: _firewallEditorFqdns
              sourceAddresses: [jumpboxSubnetPrefix]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'AllowJumpboxAcme'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: _firewallJumpboxAcmeFqdns
              sourceAddresses: [jumpboxSubnetPrefix]
            }
          ] : [],
          _deployAcrTaskAgentPool ? [
            {
              ruleType: 'ApplicationRule'
              name: 'AllowAcrTasks'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: _firewallAcrTaskFqdns
              sourceAddresses: [devopsBuildAgentsSubnetPrefix]
            }
          ] : [],
          (_deployAcrTaskAgentPool && extendFirewallForAcrTaskBuilds) ? [
            {
              ruleType: 'ApplicationRule'
              name: 'AllowAcrTaskDevRuntimes'
              protocols: [
                { protocolType: 'Https', port: 443 }
              ]
              targetFqdns: union(_firewallDevRuntimeFqdns, additionalAcrTaskBuildFqdns)
              sourceAddresses: [devopsBuildAgentsSubnetPrefix]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'AllowAcrTaskOsPackages'
              protocols: [
                { protocolType: 'Https', port: 443 }
                { protocolType: 'Http', port: 80 }
              ]
              targetFqdns: _firewallAcrTaskOsPackageFqdns
              sourceAddresses: [devopsBuildAgentsSubnetPrefix]
            }
          ] : []
        )
      }
    ]
  }
}

// ACS Media (WebRTC / TURN) — opt-in network rule collection.
// Required for Speech real-time avatar, ACS Calling, Teams Media. The signaling
// path is HTTPS (already covered by application rules); the *media* path uses
// UDP 3478-3481 / TCP 443+3478-3481 to the ACS / Speech avatar TURN fleet,
// which is otherwise dropped by the firewall under network isolation.
// Note: the destination is the `AzureCloud` service tag, not a hypothetical
// `AzureCommunicationServices` tag — the latter does not exist in the Azure
// service-tag namespace, and the actual TURN backends (e.g.
// `relay.communication.microsoft.com`,
// `a-tr-skysc-*.<region>.cloudapp.azure.com`) resolve into IP ranges covered
// by `AzureCloud` / `AzureCloud.<region>`. See issue #50.
// Separate rule collection group so it can be toggled independently of the
// default group, and so the default group's priority doesn't have to shift.
resource firewallPolicyAcsMediaRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-07-01' = if (deployAzureFirewall && _networkIsolation && enableAcsMediaEgress) {
  parent: firewallPolicy
  name: 'AcsMediaRuleCollectionGroup'
  properties: {
    priority: 300
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowAcsMedia'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowAcsMediaUdp'
            ipProtocols: ['UDP']
            sourceAddresses: [
              jumpboxSubnetPrefix
              acaEnvironmentSubnetPrefix
              agentSubnetPrefix
            ]
            destinationAddresses: ['AzureCloud']
            destinationPorts: ['3478-3481']
          }
          {
            ruleType: 'NetworkRule'
            name: 'AllowAcsMediaTcp'
            ipProtocols: ['TCP']
            sourceAddresses: [
              jumpboxSubnetPrefix
              acaEnvironmentSubnetPrefix
              agentSubnetPrefix
            ]
            destinationAddresses: ['AzureCloud']
            destinationPorts: ['443', '3478-3481']
          }
        ]
      }
    ]
  }
  dependsOn: [
    firewallPolicyDefaultRuleCollectionGroup
  ]
}

#disable-next-line BCP318
var _firewallSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${azureFirewallSubnetName}' : ''

resource azureFirewall 'Microsoft.Network/azureFirewalls@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  name: '${const.abbrs.networking.firewall}${resourceToken}'
  location: location
  tags: _tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          publicIPAddress: {
            id: firewallPublicIp.id
          }
          subnet: {
            id: _firewallSubnetId
          }
        }
      }
    ]
    firewallPolicy: {
      id: firewallPolicy.id
    }
  }
  dependsOn: [
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

// Default route through Azure Firewall (local) or external NVA/hub firewall (Gap 6).
// Skipped entirely when the operator brings their own Route Table via
// `hubIntegrationExistingRouteTableResourceId` (we don't write into a foreign RT).
resource defaultRoute 'Microsoft.Network/routeTables/routes@2024-07-01' = if (_createDefaultRoute) {
  parent: routeTable
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: _defaultRouteNextHopIp
  }
}

// Azure Firewall diagnostics to Log Analytics
resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployAzureFirewall && _networkIsolation && _hasEffectiveLaw) {
  name: 'fw-diagnostics'
  scope: azureFirewall
  properties: {
    workspaceId: _lawResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

//Test VM User Managed Identity
resource testVmUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI) {
  name: '${const.abbrs.security.managedIdentity}${_vmName}'
  location: location
}

// Test VM
module testVm 'br/public:avm/res/compute/virtual-machine:0.15.0' = if (_deployJumpbox) {
  name: 'testVmDeployment'
  params: {
    name: _vmName
    location: location
    adminUsername: _vmUserName
    adminPassword: vmAdminPassword
    managedIdentities: {
      systemAssigned: _useUAI ? false : true
      #disable-next-line BCP318
      userAssignedResourceIds: _useUAI ? [testVmUAI.id] : []
    }
    imageReference: {
      publisher: vmImagePublisher
      offer:     vmImageOffer
      sku:       vmImageSku
      version:   vmImageVersion
    }
    encryptionAtHost: false 
    vmSize: vmSize
    osDisk: {
      caching: 'ReadWrite'
      diskSizeGB: 250
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
      
    }
    osType: 'Windows'
    zone: 0
    nicConfigurations: [
      {
        nicSuffix: '-nic-01'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            #disable-next-line BCP318
            subnetResourceId: _jumpbxSubnetId
          }
        ]
      }
    ]
  }
  dependsOn: [
    testVmBastionHost
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (_deployNatGateway) {
  name: '${const.abbrs.networking.publicIPAddress}${const.abbrs.networking.natGateway}${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 30
    dnsSettings: {
      domainNameLabel: '${const.abbrs.networking.publicIPAddress}${const.abbrs.networking.natGateway}${resourceToken}'
    }
  }
  tags: _tags
}

#disable-next-line BCP081
resource natGateway 'Microsoft.Network/natGateways@2024-10-01' = if (_deployNatGateway) {
  name: '${const.abbrs.networking.natGateway}${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// TestVM role assignments (consolidated into a single array-driven module call
// to keep the compiled ARM template under the 4 MB deployment limit).
// ---------------------------------------------------------------------------
var _testVmPrincipalId = _deployJumpbox
  #disable-next-line BCP318
  ? (_useUAI ? testVmUAI.properties.principalId : testVm.outputs.systemAssignedMIPrincipalId!)
  : ''

var _testVmRoles = _deployJumpbox ? concat(
  [
    // Reader on the resource group itself so the jumpbox SAMI can enumerate
    // ARM resources from inside the VNet (`az resource list`,
    // `az cosmosdb list`, `az containerapp list`, …). Required by consumer
    // postProvision / data-seed scripts that resolve resource names by
    // discovery when env vars / App Config values are missing or the script
    // is being run interactively for troubleshooting. Without this, every
    // ARM list call returns `[]` even though the SAMI already has the
    // data-plane roles needed for the actual operations. Scoped to the
    // resource group (empty `resourceId` => deployment scope, which is RG).
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.Reader.guid)
      principalId: _testVmPrincipalId
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
  ],
  (deployAppConfig && deployContainerRegistry) ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerAppsContributor.guid)
      principalId: _testVmPrincipalId
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ManagedIdentityOperator.guid)
      principalId: _testVmPrincipalId
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryRepositoryWriter.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryContributorDataAccessConfigurationAdministrator.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryTasksContributor.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployAppConfig ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AppConfigurationDataOwner.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: appConfig.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployContainerRegistry ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPush.guid)
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployKeyVault ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultContributor.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultSecretsOfficer.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultCertificatesOfficer.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deploySearchService ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchServiceContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchIndexDataContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployAiFoundry ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesContributor.guid)
      principalId: _testVmPrincipalId
      resourceId: aiFoundryAccountResourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesOpenAIUser.guid)
      resourceId: aiFoundryAccountResourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deploySpeechService ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesContributor.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: speechService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesUser.guid)
      #disable-next-line BCP318
      resourceId: speechService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployDocumentIntelligence ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesContributor.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: documentIntelligence.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesUser.guid)
      #disable-next-line BCP318
      resourceId: documentIntelligence.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployContainerRegistry ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.Contributor.guid)
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployContainerApps ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.Contributor.guid)
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployStorageAccount ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.StorageBlobDataContributor.guid)
      #disable-next-line BCP318
      resourceId: storageAccount.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : []
) : []

module assignTestVmRoles 'modules/security/resource-role-assignment.bicep' = if (_deployJumpbox) {
  name: 'assignTestVmRoles'
  params: {
    name: 'assignTestVmRoles'
    roleAssignments: _testVmRoles
  }
}

// Cosmos DB Account - Cosmos DB Built-in Data Contributor -> TestVm
module assignCosmosDBCosmosDbBuiltInDataContributorTestVm 'modules/security/cosmos-data-plane-role-assignment.bicep' = if (_deployJumpbox && deployCosmosDb) {
  name: 'assignCosmosDBCosmosDbBuiltInDataContributorTestVm'
  params: {
    #disable-next-line BCP318
    cosmosDbAccountName: cosmosDBAccount.outputs.name
    principalId: _testVmPrincipalId
    roleDefinitionGuid: const.roles.CosmosDBBuiltInDataContributor.guid
    scopePath: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccountName}'
  }
}

var _fileUris = [
  'https://raw.githubusercontent.com/Azure/bicep-ptn-aiml-landing-zone/refs/tags/${_manifest.ailz_tag}/install.ps1'
]

resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = if (_deployJumpbox && deploySoftware) {
  name: '${_vmName}/cse'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deployment().name
    settings: {
      fileUris: _fileUris
      commandToExecute: 'powershell.exe -ExecutionPolicy Unrestricted -File install.ps1 -release ${_manifest.ailz_tag} -UseUAI ${_useUAI} -ResourceToken ${resourceToken} -AzureTenantId ${subscription().tenantId} -AzureLocation ${location} -AzureSubscriptionId ${subscription().subscriptionId} -AzureResourceGroupName ${resourceGroup().name} -AzdEnvName ${environmentName} -ExtraRepoUrls "${join(_extraRepoUrls, ',')}" -ExtraRepoTags "${join(_extraRepoTags, ',')}" -ExtraRepoNames "${join(_extraRepoNames, ',')}"'
    }
    protectedSettings: {
      
    }
  }
  dependsOn: [
    testVm
    appConfigPopulate
    assignTestVmRoles
    assignCosmosDBCosmosDbBuiltInDataContributorTestVm
    azureFirewall
    firewallPolicyDefaultRuleCollectionGroup
  ]
}

// Private DNS Zones (consolidated into a single for-loop module to keep compiled ARM template under 4 MB).
///////////////////////////////////////////////////////////////////////////

var _dnsZonesTargetRg = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _dnsZonesLinkSuffix = '${useExistingVNet ? '-byon' : ''}${empty(dnsZoneLinkSuffix) ? '' : '-${dnsZoneLinkSuffix}'}'

// Gap 2 — Per-zone BYO flags (true ⇒ skip local creation for that zone).
var _byoZoneCogSvcs        = !empty(existingPrivateDnsZoneCogSvcsResourceId ?? '')
var _byoZoneOpenAi         = !empty(existingPrivateDnsZoneOpenAiResourceId ?? '')
var _byoZoneAiServices     = !empty(existingPrivateDnsZoneAiServicesResourceId ?? '')
var _byoZoneSearch         = !empty(existingPrivateDnsZoneSearchResourceId ?? '')
var _byoZoneCosmos         = !empty(existingPrivateDnsZoneCosmosResourceId ?? '')
var _byoZoneBlob           = !empty(existingPrivateDnsZoneBlobResourceId ?? '')
var _byoZoneKeyVault       = !empty(existingPrivateDnsZoneKeyVaultResourceId ?? '')
var _byoZoneAppConfig      = !empty(existingPrivateDnsZoneAppConfigResourceId ?? '')
var _byoZoneContainerApps  = !empty(existingPrivateDnsZoneContainerAppsResourceId ?? '')
var _byoZoneAcr            = !empty(existingPrivateDnsZoneAcrResourceId ?? '')
var _byoZoneAppInsights    = !empty(existingPrivateDnsZoneAppInsightsResourceId ?? '')
var _byoZoneAzureMonitor   = !empty(existingPrivateDnsZoneAzureMonitorResourceId ?? '')
var _byoZoneOmsOpInsights  = !empty(existingPrivateDnsZoneOmsOpsInsightsResourceId ?? '')
var _byoZoneOdsOpInsights  = !empty(existingPrivateDnsZoneOdsOpsInsightsResourceId ?? '')
var _byoZoneAzureAutomation= !empty(existingPrivateDnsZoneAzureAutomationResourceId ?? '')

var _dnsZonesList = _deployPrivateDnsZones ? concat(
  _byoZoneCogSvcs       ? [] : [ { dnsName: 'privatelink.cognitiveservices.azure.com', virtualNetworkLinkName: '${vnetName}-cogsvcs-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneOpenAi        ? [] : [ { dnsName: 'privatelink.openai.azure.com',            virtualNetworkLinkName: '${vnetName}-openai-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneAiServices    ? [] : [ { dnsName: 'privatelink.services.ai.azure.com',       virtualNetworkLinkName: '${vnetName}-aiservices-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneSearch        ? [] : [ { dnsName: 'privatelink.search.windows.net',          virtualNetworkLinkName: '${vnetName}-search-std-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneCosmos        ? [] : [ { dnsName: 'privatelink.documents.azure.com',         virtualNetworkLinkName: '${vnetName}-cosmos-std-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneBlob          ? [] : [ { dnsName: 'privatelink.blob.${environment().suffixes.storage}', virtualNetworkLinkName: '${vnetName}-blob-std-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneKeyVault      ? [] : [ { dnsName: 'privatelink.vaultcore.azure.net',         virtualNetworkLinkName: '${vnetName}-kv-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneAppConfig     ? [] : [ { dnsName: 'privatelink.azconfig.io',                 virtualNetworkLinkName: '${vnetName}-appcfg-link${_dnsZonesLinkSuffix}' } ],
  (deployContainerApps && !_byoZoneContainerApps) ? [
    { dnsName: 'privatelink.${location}.azurecontainerapps.io', virtualNetworkLinkName: '${vnetName}-containerapps-link${_dnsZonesLinkSuffix}' }
  ] : [],
  (deployContainerRegistry && !_byoZoneAcr) ? [
    { dnsName: 'privatelink.${acrDnsSuffix}',                         virtualNetworkLinkName: '${vnetName}-containerregistry-link${_dnsZonesLinkSuffix}' }
  ] : [],
  _deployAmpls ? concat(
    _byoZoneAppInsights     ? [] : [ { dnsName: 'privatelink.applicationinsights.io',      virtualNetworkLinkName: '${vnetName}-appi-link${_dnsZonesLinkSuffix}' } ],
    _byoZoneAzureMonitor    ? [] : [ { dnsName: 'privatelink.monitor.azure.com',           virtualNetworkLinkName: '${vnetName}-azure-monitor-link${_dnsZonesLinkSuffix}' } ],
    _byoZoneOmsOpInsights   ? [] : [ { dnsName: 'privatelink.oms.opinsights.azure.com',    virtualNetworkLinkName: '${vnetName}-oms-opinsights-link${_dnsZonesLinkSuffix}' } ],
    _byoZoneOdsOpInsights   ? [] : [ { dnsName: 'privatelink.ods.opinsights.azure.com',    virtualNetworkLinkName: '${vnetName}-ods-opinsights-link${_dnsZonesLinkSuffix}' } ],
    _byoZoneAzureAutomation ? [] : [ { dnsName: 'privatelink.agentsvc.azure.automation.net', virtualNetworkLinkName: '${vnetName}-azure-automation-link${_dnsZonesLinkSuffix}' } ]
  ) : []
) : []

module privateDnsZones 'modules/networking/private-dns-zones.bicep' = if (_deployPrivateDnsZones && !empty(_dnsZonesList)) {
  name: 'dep-private-dns-zones'
  params: {
    zones: _dnsZonesList
    tags: _tags
    resourceGroupName: _dnsZonesTargetRg
    virtualNetworkResourceId: virtualNetworkResourceId
  }
  dependsOn: [
    virtualNetwork!
    virtualNetworkSubnets!
  ]
}

// Private Endpoints (consolidated into a single for-loop module with @batchSize(1) to keep compiled ARM template under 4 MB while preserving serialized PE creation).
///////////////////////////////////////////////////////////////////////////

var _peDnsZoneGroupBlob = policyManagedPrivateDns ? null : {
  name: 'blobDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'blobARecord', privateDnsZoneResourceId: _dnsZoneBlobId }
  ]
}
var _peDnsZoneGroupCosmos = policyManagedPrivateDns ? null : {
  name: 'cosmosDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'cosmosARecord', privateDnsZoneResourceId: _dnsZoneCosmosId }
  ]
}
var _peDnsZoneGroupSearch = policyManagedPrivateDns ? null : {
  name: 'searchDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'searchARecord', privateDnsZoneResourceId: _dnsZoneSearchId }
  ]
}
var _peDnsZoneGroupKeyVault = policyManagedPrivateDns ? null : {
  name: 'kvDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'kvARecord', privateDnsZoneResourceId: _dnsZoneKeyVaultId }
  ]
}
var _peDnsZoneGroupAppConfig = policyManagedPrivateDns ? null : {
  name: 'appConfigDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'appConfigARecord', privateDnsZoneResourceId: _dnsZoneAppConfigId }
  ]
}
var _peDnsZoneGroupContainerApps = policyManagedPrivateDns ? null : {
  name: 'ccaDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'ccaARecord', privateDnsZoneResourceId: _dnsZoneContainerAppsId }
  ]
}
var _peDnsZoneGroupAcr = policyManagedPrivateDns ? null : {
  name: 'acrDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'acr', privateDnsZoneResourceId: _dnsZoneAcrId }
  ]
}
var _peDnsZoneGroupCogSvcs = policyManagedPrivateDns ? null : {
  name: 'cogSvcsDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'cogSvcsARecord', privateDnsZoneResourceId: _dnsZoneCogSvcsId }
  ]
}

var _peList = concat(
  (_networkIsolation && deployStorageAccount) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${storageAccountName}'
      privateLinkServiceConnections: [
        {
          name: 'blobConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: storageAccount.outputs.resourceId, groupIds: ['blob'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupBlob
    }
  ] : [],
  (_networkIsolation && deployCosmosDb) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${dbAccountName}'
      privateLinkServiceConnections: [
        {
          name: 'cosmosConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: cosmosDBAccount.outputs.resourceId, groupIds: ['Sql'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupCosmos
    }
  ] : [],
  (_networkIsolation && deploySearchService) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${searchServiceName}'
      privateLinkServiceConnections: [
        {
          name: 'searchConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: searchService.outputs.resourceId, groupIds: ['searchService'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupSearch
    }
  ] : [],
  (_networkIsolation && deployAiFoundry && deploySearchService && aiSearchResourceId == '') ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${aiFoundrySearchServiceName}'
      privateLinkServiceConnections: [
        {
          name: 'searchAIFConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: searchServiceAIFoundry.outputs.resourceId, groupIds: ['searchService'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupSearch
    }
  ] : [],
  (_networkIsolation && deployKeyVault) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${keyVaultName}'
      privateLinkServiceConnections: [
        {
          name: 'kvConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: keyVault.id, groupIds: ['vault'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupKeyVault
    }
  ] : [],
  (_networkIsolation && deployAppConfig) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${appConfigName}'
      privateLinkServiceConnections: [
        {
          name: 'appConfigConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: appConfig.id, groupIds: ['configurationStores'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupAppConfig
    }
  ] : [],
  (_networkIsolation && deployContainerEnv) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${containerEnvName}'
      privateLinkServiceConnections: [
        {
          name: 'ccaConnection'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: containerEnv.id, groupIds: ['managedEnvironments'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupContainerApps
    }
  ] : [],
  (_networkIsolation && deployContainerRegistry) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${containerRegistryName}'
      privateLinkServiceConnections: [
        {
          name: '${containerRegistryName}-registry-connection'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: containerRegistry.id, groupIds: ['registry'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupAcr
    }
  ] : [],
  (_networkIsolation && deploySpeechService) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${speechServiceName}'
      privateLinkServiceConnections: [
        {
          name: 'speechConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: speechService.outputs.resourceId, groupIds: ['account'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupCogSvcs
    }
  ] : [],
  (_networkIsolation && deployDocumentIntelligence) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${documentIntelligenceName}'
      privateLinkServiceConnections: [
        {
          name: 'docIntelConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: documentIntelligence.outputs.resourceId, groupIds: ['account'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupCogSvcs
    }
  ] : []
)

module privateEndpoints 'modules/networking/private-endpoints.bicep' = if (_networkIsolation) {
  name: 'dep-private-endpoints'
  params: {
    endpoints: _peList
    location: _peLocation
    resourceGroupName: _peResourceGroupName
    tags: _tags
    subnetResourceId: _peSubnetId
  }
  dependsOn: [
    privateDnsZones
    storageAccount!
    cosmosDBAccount!
    searchService!
    searchServiceAIFoundry!
    keyVault!
    appConfig!
    containerEnv!
    containerRegistry!
    speechService!
    documentIntelligence!
  ]
}


// Azure Application Gateway
//////////////////////////////////////////////////////////////////////////
// Coming Soon

// Azure Firewall
//////////////////////////////////////////////////////////////////////////
// Coming Soon

// AI Foundry Standard Setup
//////////////////////////////////////////////////////////////////////////


var _dnsZonesSubscriptionId = useExistingVNet && !sideBySideDeploy ? varExistingVnetSubscriptionId : subscription().subscriptionId
var _dnsZonesResourceGroupName = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _dnsZoneCogSvcsId         = !empty(existingPrivateDnsZoneCogSvcsResourceId ?? '')         ? existingPrivateDnsZoneCogSvcsResourceId!         : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.cognitiveservices.azure.com')
var _dnsZoneOpenAiId          = !empty(existingPrivateDnsZoneOpenAiResourceId ?? '')          ? existingPrivateDnsZoneOpenAiResourceId!          : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.openai.azure.com')
var _dnsZoneAiServicesId      = !empty(existingPrivateDnsZoneAiServicesResourceId ?? '')      ? existingPrivateDnsZoneAiServicesResourceId!      : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.services.ai.azure.com')
var _dnsZoneSearchId          = !empty(existingPrivateDnsZoneSearchResourceId ?? '')          ? existingPrivateDnsZoneSearchResourceId!          : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')
var _dnsZoneCosmosId          = !empty(existingPrivateDnsZoneCosmosResourceId ?? '')          ? existingPrivateDnsZoneCosmosResourceId!          : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')
var _dnsZoneBlobId            = !empty(existingPrivateDnsZoneBlobResourceId ?? '')            ? existingPrivateDnsZoneBlobResourceId!            : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
var _dnsZoneKeyVaultId        = !empty(existingPrivateDnsZoneKeyVaultResourceId ?? '')        ? existingPrivateDnsZoneKeyVaultResourceId!        : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net')
var _dnsZoneAppConfigId       = !empty(existingPrivateDnsZoneAppConfigResourceId ?? '')       ? existingPrivateDnsZoneAppConfigResourceId!       : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.azconfig.io')
var _dnsZoneContainerAppsId   = !empty(existingPrivateDnsZoneContainerAppsResourceId ?? '')   ? existingPrivateDnsZoneContainerAppsResourceId!   : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.${location}.azurecontainerapps.io')
var _dnsZoneAcrId             = !empty(existingPrivateDnsZoneAcrResourceId ?? '')             ? existingPrivateDnsZoneAcrResourceId!             : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.${acrDnsSuffix}')
var _dnsZoneAzureMonitorId    = !empty(existingPrivateDnsZoneAzureMonitorResourceId ?? '')    ? existingPrivateDnsZoneAzureMonitorResourceId!    : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.monitor.azure.com')
var _dnsZoneOmsOpsInsightsId  = !empty(existingPrivateDnsZoneOmsOpsInsightsResourceId ?? '')  ? existingPrivateDnsZoneOmsOpsInsightsResourceId!  : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.oms.opinsights.azure.com')
var _dnsZoneOdsOpsInsightsId  = !empty(existingPrivateDnsZoneOdsOpsInsightsResourceId ?? '')  ? existingPrivateDnsZoneOdsOpsInsightsResourceId!  : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.ods.opinsights.azure.com')
var _dnsZoneAzureAutomationId = !empty(existingPrivateDnsZoneAzureAutomationResourceId ?? '') ? existingPrivateDnsZoneAzureAutomationResourceId! : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.agentsvc.azure.automation.net')

//AI Foundry Account User Managed Identity
resource aiFoundryUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI) {
  name: '${const.abbrs.security.managedIdentity}${aiFoundryAccountName}'
  location: location
}

// 16.0 AI Foundry account creation is delegated entirely to the customized
// derivation of avm/ptn/ai-ml/ai-foundry@0.6.0 maintained at
// `modules/ai-foundry/foundry/`. The customized `account.bicep` therein
// splits account creation from private-endpoint creation and adds an
// explicit deploymentScript wait on `provisioningState == Succeeded`, which
// closes the race the previous pre-create workaround tried (and failed) to
// mask via property-matching. See issues #25, #26, #27 for the full history.

// Pre-create AI Foundry Storage Account with a region-safe SKU.
// The AVM ai-foundry module (<= 0.6.0) creates its Storage Account with the
// provider default `Standard_GRS`, which is not offered in every region
// (e.g. Poland Central -> RedundancyConfigurationNotAvailableInRegion).
// Creating it ourselves and passing the resource ID as `existingResourceId`
// lets us honor an explicit SKU (default `Standard_LRS`).
module aiFoundryStorageAccount 'modules/ai-foundry/storage-account.bicep' = if (deployAiFoundry && aiFoundryStorageAccountResourceId == '') {
  name: 'aiFoundryStorage-${resourceToken}-deployment'
  params: {
    name: aiFoundryStorageAccountName
    location: location
    tags: _tags
    skuName: aiFoundryStorageSku
    disablePublicNetworkAccess: _networkIsolation
    allowedIpRanges: allowedIpRanges
    privateEndpointSubnetResourceId: _networkIsolation ? _peSubnetId : ''
    blobPrivateDnsZoneResourceId: (_networkIsolation && !policyManagedPrivateDns) ? _dnsZoneBlobId : ''
  }
  dependsOn: [
    #disable-next-line BCP321
    (_networkIsolation && !useExistingVNet) ? virtualNetwork : null
    #disable-next-line BCP321
    (_networkIsolation && useExistingVNet && deploySubnets) ? virtualNetworkSubnets : null
    #disable-next-line BCP321
    (_networkIsolation && !policyManagedPrivateDns) ? privateDnsZones : null
    // `privateEndpoints` module creates ~10 PEs against `pe-subnet` (already serialized
    // internally via @batchSize(1)). This module also creates an inline blob PE on the
    // same subnet via the AVM storage-account module's `privateEndpoints` parameter.
    // Without this dependsOn, the inline PE NIC and the aggregator's PE NICs race the
    // subnet update and ARM intermittently fails one of them with
    // `ReferencedResourceNotProvisioned`.
    #disable-next-line BCP321
    _networkIsolation ? privateEndpoints : null
  ]
}


// 16.1 AI Foundry Configuration
module aiFoundry 'modules/ai-foundry/main.bicep' = if (deployAiFoundry) {
  name: '${aiFoundryAccountName}-${resourceToken}-deployment'
  params: {
    // Required
    baseName: substring(resourceToken, 0, 10)

    includeAssociatedResources: false
    location: location
    tags: deploymentTags

    // Gate this on `_networkIsolation` to mirror the sibling `aiFoundryStorageAccount`
    // module at L2220. When network isolation is off, the spoke VNet is not deployed,
    // `virtualNetworkResourceId` resolves to '', and `varPeSubnetId` collapses to the
    // bogus literal '/subnets/pe-subnet'. Passing that down to the four AI Foundry-
    // bundled sub-modules (Cosmos, Key Vault, AI Search, Storage) makes each one's
    // `privateNetworkingEnabled = !empty(privateEndpointSubnetResourceId)` evaluate
    // true (the string is non-empty but invalid), and ARM template validation fails
    // with `databaseAccount_privateEndpoints[0]` / `keyVault_privateEndpoints[0]` ...
    // `'reference' is not valid: all function arguments should be string literals.`.
    // See issue #63 for the full diagnosis.
    privateEndpointSubnetResourceId: _networkIsolation ? varPeSubnetId : ''

    aiFoundryConfiguration: {
      accountName: aiFoundryAccountName
      allowProjectManagement: deployAfProject
      createCapabilityHosts: deployAAfAgentSvc
      location: location

      networking: varAfNetworkingOverride

      project: deployAfProject
        ? {
            name: 'aifoundry-default-project'
            displayName: 'Default AI Foundry Project.'
            description: 'This is the default project for AI Foundry.'
          }
        : null
    }

    aiModelDeployments: !empty(modelDeploymentList)
      ? modelDeploymentList
      : [
          {
            model: {
              format: 'OpenAI'
              name: 'gpt-5-nano'
              version: '2025-08-07'
            }
            name: 'gpt-5-nano'
            sku: {
              name: 'GlobalStandard'
              capacity: 40
            }
          }
          {
            model: {
              format: 'OpenAI'
              name: 'text-embedding-3-large'
              version: '1'
            }
            name: 'text-embedding-3-large'
            sku: {
              name: 'Standard'
              capacity: 10
            }
          }
        ]

    aiSearchConfiguration: varAfAiSearchCfgComplete
    cosmosDbConfiguration: varAfCosmosCfgComplete
    keyVaultConfiguration: varAfKVCfgComplete
    storageAccountConfiguration: varAfStorageCfgComplete

    enableTelemetry: true
  }
  dependsOn: [
    #disable-next-line BCP321
    (deploySearchService && aiSearchResourceId == '') ? searchServiceAIFoundry : null
    #disable-next-line BCP321
    (_networkIsolation && !useExistingVNet) ? virtualNetwork : null
    #disable-next-line BCP321
    (_networkIsolation && useExistingVNet && deploySubnets) ? virtualNetworkSubnets : null
    #disable-next-line BCP321
    _networkIsolation ? privateDnsZones : null
    #disable-next-line BCP321
    (aiFoundryStorageAccountResourceId == '') ? aiFoundryStorageAccount : null
    // Serialize AI Foundry's internal PE creation against the shared `pe-subnet`
    // (fixes #41). The AVM ai-foundry module creates its own cog-svc PEs on the
    // same subnet used by the `privateEndpoints` aggregator and by the inline blob
    // PE in `aiFoundryStorageAccount`. Without this dependsOn, the AVM-internal PE
    // NICs race the subnet update and ARM intermittently fails one of them with
    // `ReferencedResourceNotProvisioned`.
    #disable-next-line BCP321
    _networkIsolation ? privateEndpoints : null
  ]
}


var varPeSubnetId = empty(existingVnetResourceId!)
  ? '${virtualNetworkResourceId}/subnets/pe-subnet'
  : '${existingVnetResourceId!}/subnets/pe-subnet'

var varAfNetworkingOverride = _networkIsolation
  ? (policyManagedPrivateDns
    ? {
        agentServiceSubnetResourceId: deployAiFoundrySubnet ? _agentSubnetId : null
      }
    : {
        cognitiveServicesPrivateDnsZoneResourceId: _dnsZoneCogSvcsId
        openAiPrivateDnsZoneResourceId: _dnsZoneOpenAiId
        aiServicesPrivateDnsZoneResourceId: _dnsZoneAiServicesId
        agentServiceSubnetResourceId: deployAiFoundrySubnet ? _agentSubnetId : null
      })
  : null

var varAfAiSearchCfgComplete = deploySearchService ? {
  existingResourceId: aiSearchResourceId != ''
    ? aiSearchResourceId
    : deployAiFoundry ? searchServiceAIFoundry.outputs.resourceId : null
  name: aiFoundrySearchServiceName
  privateDnsZoneResourceId: (_networkIsolation && !policyManagedPrivateDns) ? _dnsZoneSearchId : null
  roleAssignments: []
} : null

var varAfCosmosCfgComplete = {
  existingResourceId: aiFoundryCosmosDBAccountResourceId != '' ? aiFoundryCosmosDBAccountResourceId : null
  name: aiFoundryCosmosDbName
  privateDnsZoneResourceId: (_networkIsolation && !policyManagedPrivateDns) ? _dnsZoneCosmosId : null
  roleAssignments: []
}

var varAfKVCfgComplete = {
  existingResourceId: keyVaultResourceId != '' ? keyVaultResourceId : null
  name: '${const.abbrs.security.keyVault}ai-${resourceToken}'
  privateDnsZoneResourceId: (_networkIsolation && !policyManagedPrivateDns) ? _dnsZoneKeyVaultId : null
  roleAssignments: []
}

// NOTE: The AVM ai-foundry `storageAccountConfigurationType` does not expose
// a `skuName` field. We instead pre-create the Storage Account in
// `aiFoundryStorageAccount` above with the requested SKU and pass its
// resource ID here as `existingResourceId`, which causes the AVM to skip
// internal storage creation (and its default `Standard_GRS`).
var varAfStorageCfgComplete = {
  existingResourceId: aiFoundryStorageAccountResourceId != ''
    ? aiFoundryStorageAccountResourceId
    : (deployAiFoundry ? aiFoundryStorageAccount.outputs.resourceId : null)
  name: aiFoundryStorageAccountName
  blobPrivateDnsZoneResourceId: (_networkIsolation && !policyManagedPrivateDns) ? _dnsZoneBlobId : null
  roleAssignments: []
}

var aiFoundryAccountResourceId = resourceId('Microsoft.CognitiveServices/accounts', aiFoundry!.outputs.aiServicesName)

var aiFoundryProjectResourceId = resourceId(
  'Microsoft.CognitiveServices/accounts/projects', 
  aiFoundry!.outputs.aiServicesName, 
  aiFoundry!.outputs.aiProjectName 
)

var aiFoundryAccountEndpoint = 'https://${aiFoundry!.outputs.aiServicesName}.cognitiveservices.azure.com/'

var aiFoundryProjectEndpoint = 'https://${aiFoundry!.outputs.aiServicesName}.services.ai.azure.com/api/projects/${aiFoundry!.outputs.aiProjectName}'

// Bing Search Connection (optional)
module bingSearchConnection 'modules/bing-search/main.bicep' = if (deployAiFoundry && deployGroundingWithBing) {
  name: 'bingSearchConnection-${resourceToken}'
  params: {
    accountName: aiFoundry!.outputs.aiServicesName
    projectName: aiFoundry!.outputs.aiProjectName
    bingSearchName: bingSearchName
  }
  dependsOn: [
    aiFoundry!
  ]
}

// AI Foundry Connections
//////////////////////////////////////////////////////////////////////////

// Bing Search Connection
module aiFoundryBingConnection 'modules/ai-foundry/connection-bing-search-tool.bicep' = if (deployAiFoundry && deployGroundingWithBing) {
  name: '${bingSearchName}-connection'
  params: {
    account_name: aiFoundry!.outputs.aiServicesName
    project_name: aiFoundry!.outputs.aiProjectName
    bingSearchName: bingSearchName
  }
  dependsOn: [
    aiFoundry!
  ]
}

// AI Search Connection
module aiFoundryConnectionSearch 'modules/ai-foundry/connection-ai-search.bicep' = if (deployAiFoundry && deploySearchService) {
  name: 'connection-ai-search-${resourceToken}'
  params: {
    aiFoundryName: aiFoundry!.outputs.aiServicesName
    aiProjectName: aiFoundry!.outputs.aiProjectName
    connectedResourceName: searchService!.outputs.name
  }
  dependsOn: [
    aiFoundry!
    searchService!
  ]
}

// Application Insights Connection
module aiFoundryConnectionInsights 'modules/ai-foundry/connection-application-insights.bicep' = if (deployAiFoundry && _hasEffectiveAI) {
  name: 'connection-appinsights-${resourceToken}'
  params: {
    aiFoundryName: aiFoundry!.outputs.aiServicesName
    connectedResourceId: _appInsightsResourceId
  }
  dependsOn: [
    aiFoundry!
    #disable-next-line BCP321
    _createAppInsights ? appInsights : null
  ]
}

// Storage Account Connection
module aiFoundryConnectionStorage 'modules/ai-foundry/connection-storage-account.bicep' = if (deployAiFoundry && deployStorageAccount) {
  name: 'connection-storage-account-${resourceToken}'
  params: {
    aiFoundryName: aiFoundry!.outputs.aiServicesName
    connectedResourceName: storageAccount!.outputs.name
  }
  dependsOn: [
    aiFoundry!
    storageAccount!
  ]
}

// Application Insights
//////////////////////////////////////////////////////////////////////////
var appInsightsInvalidLocations = ['westcentralus']

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (_createAppInsights) {
  name: appInsightsName
  location: contains(appInsightsInvalidLocations, location) ? 'eastus' : location
  kind: 'web'
  tags: _tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: _lawResourceId
    DisableIpMasking: false
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

//private link scope
resource privateLinkScope 'microsoft.insights/privatelinkscopes@2021-07-01-preview' = if (_deployAmpls) {
  name: '${const.abbrs.networking.privateLinkScope}${resourceToken}'
  location: 'global'
  properties :{
    accessModeSettings : {
      queryAccessMode : 'Open'
      ingestionAccessMode : 'Open'
    }
  }
  dependsOn: [
    appInsights!
  ]
}

module privateEndpointPrivateLinkScope 'modules/networking/private-endpoint.bicep' = if (_deployAmpls) {
  name: 'privatelink-scope-private-endpoint'
  params: {
    name: '${const.abbrs.networking.privateEndpoint}${const.abbrs.networking.privateLinkScope}${resourceToken}'
    location: _peLocation
    resourceGroupName: _peResourceGroupName
    tags: _tags
    subnetResourceId: _peSubnetId
    privateLinkServiceConnections: [
      {
        name: 'privateLinkScopeConnection'
        properties: {
          privateLinkServiceId: privateLinkScope.id
          groupIds: ['azuremonitor']
        }
      }
    ]
    privateDnsZoneGroup: policyManagedPrivateDns ? null : {
      name: 'privateLinkDnsZoneGroup'
      privateDnsZoneGroupConfigs: [
        { name: 'azuremonitorARecord', privateDnsZoneResourceId: _dnsZoneAzureMonitorId }
        { name: 'omsinsightsARecord',  privateDnsZoneResourceId: _dnsZoneOmsOpsInsightsId }
        { name: 'odsinsightsARecord',  privateDnsZoneResourceId: _dnsZoneOdsOpsInsightsId }
        { name: 'automationARecord',   privateDnsZoneResourceId: _dnsZoneAzureAutomationId }
      ]
    }
  }
  dependsOn: [
    privateLinkScope!
    privateDnsZones
    privateEndpoints // Serialize PE operations to avoid conflicts
  ]
}

resource privateLinkScopedResources1 'microsoft.insights/privatelinkscopes/scopedresources@2021-07-01-preview' = if (_deployAmpls) {
  name: '${const.abbrs.networking.privateLinkScope}${resourceToken}/${logAnalyticsWorkspaceName}'!
  properties :{
    #disable-next-line BCP318
    linkedResourceId: _lawResourceId
  }
  dependsOn: [
    privateLinkScope
  ]
}

resource privateLinkScopedResources2 'microsoft.insights/privatelinkscopes/scopedresources@2021-07-01-preview' = if (_deployAmpls) {
  name: '${const.abbrs.networking.privateLinkScope}${resourceToken}/${appInsightsName}'!
  properties :{
    linkedResourceId: _appInsightsResourceId
  }
  dependsOn: [
    privateLinkScope
  ]
}

// Container Resources
//////////////////////////////////////////////////////////////////////////

//Container Apps Env User Managed Identity
resource containerEnvUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI && deployContainerEnv) {
  name: '${const.abbrs.security.managedIdentity}${containerEnvName}'
  location: location
}

// Container Apps Environment
resource containerEnv 'Microsoft.App/managedEnvironments@2025-01-01' = if (deployContainerEnv) {
  name: containerEnvName
  location: location
  tags: _tags
  identity: {
    type: _useUAI ? 'UserAssigned' : 'SystemAssigned'
    userAssignedIdentities: _useUAI ? { '${containerEnvUAI.id}': {} } : null
  }
  properties: {
    appLogsConfiguration: {
      destination: null
    }
    appInsightsConfiguration: _hasEffectiveAI ? {
      connectionString: _appInsightsConnectionString
    } : null
    zoneRedundant: useZoneRedundancy
    workloadProfiles: workloadProfiles
    vnetConfiguration: networkIsolation ? {
      infrastructureSubnetId: _caEnvSubnetId
      internal: true
    } : null
  }
  dependsOn: [
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

//Container Registry User Managed Identity
resource containerRegistryUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI && deployContainerRegistry) {
  name: '${const.abbrs.security.managedIdentity}${containerRegistryName}'
  location: location
}

// Container Registry
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = if (deployContainerRegistry) {
  name: containerRegistryName
  location: location
  tags: _tags
  sku: {
    name: _networkIsolation ? 'Premium' : 'Basic'
  }
  identity: {
    type: _useUAI ? 'UserAssigned' : 'SystemAssigned'
    userAssignedIdentities: _useUAI ? { '${containerRegistryUAI.id}': {} } : null
  }
  properties: {
    publicNetworkAccess: _publicNetworkAccess
    zoneRedundancy: useZoneRedundancy ? 'Enabled' : 'Disabled'
    dataEndpointEnabled: _networkIsolation
    networkRuleSet: _applyIpRules ? {
      defaultAction: 'Deny'
      ipRules: _acrIpRules
    } : null
    policies: {
      exportPolicy: {
        status: 'enabled'
      }
    }
  }
}

// ACR Task agent pool — enables `az acr build --agent-pool <name>` to run image
// builds inside the VNet when publicNetworkAccess on the registry is Disabled.
// Gated on networkIsolation (Premium SKU) and deployAcrTaskAgentPool.
resource acrTaskAgentPool 'Microsoft.ContainerRegistry/registries/agentPools@2019-06-01-preview' = if (_deployAcrTaskAgentPool) {
  parent: containerRegistry
  name: acrTaskAgentPoolName
  location: location
  tags: _tags
  properties: {
    count: acrTaskAgentPoolCount
    tier: acrTaskAgentPoolTier
    os: 'Linux'
    #disable-next-line BCP318
    virtualNetworkSubnetResourceId: _networkIsolation ? '${virtualNetworkResourceId}/subnets/${devopsBuildAgentsSubnetName}' : ''
  }
}

//Container Apps User Managed Identity
resource containerAppsUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for app in containerAppsList: if (_useUAI && deployContainerApps) {
    name: '${const.abbrs.security.managedIdentity}${const.abbrs.containers.containerApp}${resourceToken}-${app.service_name}'
    location: location
  }
]

// Dedicated ACR pull identity — shared across all container apps so they can
// authenticate with the private container registry independently of _useUAI.
resource acrPullUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployContainerApps && deployContainerRegistry) {
  name: '${const.abbrs.security.managedIdentity}acr-pull-${resourceToken}'
  location: location
}

// Container Apps
@batchSize(4)
module containerApps 'br/public:avm/res/app/container-app:0.18.1' = [
  for (app, index) in containerAppsList: if (deployContainerApps) {
    name: empty(app.name) ? '${const.abbrs.containers.containerApp}${resourceToken}-${app.service_name}' : app.name
    params: {
      name: empty(app.name) ? '${const.abbrs.containers.containerApp}${resourceToken}-${app.service_name}' : app.name
      location: location
      #disable-next-line BCP318
      environmentResourceId: containerEnv.id
      workloadProfileName: app.profile_name

      ingressExternal: app.external
      ingressTargetPort: int(app.?target_port ?? 8080)
      ingressTransport: 'auto'
      ingressAllowInsecure: false

      dapr: {
        enabled: true
        appId: app.service_name
        appPort: int(app.?target_port ?? 8080)
        appProtocol: 'http'
      }

      managedIdentities: {
        systemAssigned: (_useUAI) ? false : true
        #disable-next-line BCP318
        userAssignedResourceIds: concat(
          (_useUAI) ? [containerAppsUAI[index].id] : [],
          deployContainerRegistry ? [acrPullUAI.id] : []
        )
      }

      registries: deployContainerRegistry ? [
        {
          server: '${containerRegistryName}.azurecr.io'
          identity: acrPullUAI.id
        }
      ] : []

      scaleSettings: {
        minReplicas: app.min_replicas
        maxReplicas: app.max_replicas
      }

      containers: [
        {
          name: app.service_name
          image: _containerDummyImageName
          resources: {
            cpu: app.?cpu ?? '0.5'
            memory: app.?memory ?? '1.0Gi'
          }
          env: concat(
            [
              {
                name: 'APP_CONFIG_ENDPOINT'
                value: 'https://${appConfigName}.azconfig.io'
              }
              {
                name: 'AZURE_TENANT_ID'
                value: subscription().tenantId
              }
            ],
            // Only inject AZURE_CLIENT_ID when a UAI is actually configured (#38).
            // Emitting an empty AZURE_CLIENT_ID alongside AZURE_TENANT_ID breaks
            // DefaultAzureCredential on the SystemAssigned path: EnvironmentCredential
            // sees both vars and tries to authenticate with the empty client_id, then
            // ManagedIdentityCredential hits the Container Apps IMDS proxy with the
            // empty client_id and gets HTTP 500 invalid_scope. With the var omitted,
            // ManagedIdentityCredential picks up the platform-injected
            // IDENTITY_ENDPOINT / IDENTITY_HEADER and uses the SystemAssigned MI.
            _useUAI ? [
              {
                name: 'AZURE_CLIENT_ID'
                #disable-next-line BCP318
                value: containerAppsUAI[index].properties.clientId
              }
            ] : []
          )
        }
      ]

      tags: union(_tags, {
        'azd-service-name': app.service_name
      })
    }
    dependsOn: [
      containerEnv!                   
      privateDnsZones
      privateEndpoints
    ]
  }
]

// Cosmos DB Account and Database
//////////////////////////////////////////////////////////////////////////

//Cosmos User Managed Identity
resource cosmosUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI) {
  name: '${const.abbrs.security.managedIdentity}${dbAccountName}'
  location: location
}

module cosmosDBAccount 'br/public:avm/res/document-db/database-account:0.15.1' = if (deployCosmosDb) {
  name: 'CosmosDBAccount'
  params: {
    name: dbAccountName
    location: cosmosLocation
    managedIdentities: {
      systemAssigned: _useUAI ? false : true
      #disable-next-line BCP318
      userAssignedResourceIds: _useUAI ? [cosmosUAI.id] : []
    }
    failoverLocations: [
      {
        locationName: cosmosLocation
        failoverPriority: 0
        isZoneRedundant: useZoneRedundancy
      }
    ]
    defaultConsistencyLevel: 'Session'
    capabilitiesToAdd: ['EnableServerless']
    enableAnalyticalStorage: enableCosmosAnalyticalStorage
    enableFreeTier: false
    networkRestrictions: {
      publicNetworkAccess: _publicNetworkAccess
      ipRules: _cosmosIpRules
      virtualNetworkRules: _networkIsolation ? [
        {
          subnetResourceId: _peSubnetId
          ignoreMissingVnetServiceEndpoint: true
        }
        {
          subnetResourceId: _caEnvSubnetId
          ignoreMissingVnetServiceEndpoint: true
        }
      ] : []
    }
    tags: _tags
    sqlDatabases: [
      {
        name: dbDatabaseName
        throughput: dbDatabaseThroughput
        containers: [
          for container in databaseContainersList: {
            name: container.name
            paths: [container.partitionKey]
            defaultTtl: -1
            throughput: container.?throughput
            indexingPolicy: container.?indexingPolicy
          }
        ]
      }
    ]
  }
  dependsOn: [
    #disable-next-line BCP321
    (_networkIsolation) ? virtualNetwork : null
  ]
}

// Key Vault
//////////////////////////////////////////////////////////////////////////

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = if (deployKeyVault) {
  name: keyVaultName
  location: location
  tags: _tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: _publicNetworkAccess
    networkAcls: _applyIpRules ? {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: _keyVaultIpRules
    } : null
  }
}

// Provision Container App secrets in Key Vault (only happens when useAPIKeys is true)
resource secret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = [for (config, i) in _containerAppsKeyVaultKeys: {
  parent: keyVault
  name: replace(config.name, '_', '-')
  properties: {
      contentType: config.contentType
      value:  config.value
  }
  tags: {}
}
]

// Log Analytics Workspace
//////////////////////////////////////////////////////////////////////////

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (_createLogAnalytics) {
  name: logAnalyticsWorkspaceName
  location: location
  tags: _tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      disableLocalAuth: false
    }
  }
}

// AI Search
//////////////////////////////////////////////////////////////////////////

//Search Service User Managed Identity
resource searchServiceUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI && deploySearchService) {
  name: '${const.abbrs.security.managedIdentity}${searchServiceName}'
  location: _searchServiceLocation
}

module searchService 'br/public:avm/res/search/search-service:0.11.1' = if (deploySearchService) {
  name: 'searchService'
  params: {
    name: searchServiceName
    location: _searchServiceLocation
    publicNetworkAccess: _publicNetworkAccess
    networkRuleSet: _applyIpRules ? {
      bypass: 'AzureServices'
      ipRules: _searchIpRules
    } : null
    tags: _tags

    // SKU & capacity
    // Using 'standard' rather than 'basic' because several regions (eastus2, westus3, etc.)
    // are returning InsufficientResourcesAvailable for the basic SKU capacity pool. Standard
    // has broader capacity availability at ~same cost tier when kept at 1 replica / 1 partition.
    sku: 'standard'
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'disabled'

    // Identity & Auth
    managedIdentities: {
      systemAssigned: _useUAI ? false : true
      #disable-next-line BCP318
      userAssignedResourceIds: _useUAI ? [searchServiceUAI.id] : []
    }

    disableLocalAuth: false
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    sharedPrivateLinkResources: _networkIsolation
      ? [
          // {
          //   groupId: 'blob'
          //   #disable-next-line BCP318
          //   privateLinkResourceId: storageAccount.outputs.resourceId
          //   requestMessage: 'Automated link for Storage'
          //   provisioningState: 'Succeeded'
          //   status: 'Approved'
          // }
        ]
      : []
  }
  dependsOn: [
    containerEnv!
    storageAccount!
  ]
}

// Dedicated AI Search service for AI Foundry (separate from the application search).
// Skipped when the consumer brings their own AI Foundry search via `aiSearchResourceId`.
module searchServiceAIFoundry 'br/public:avm/res/search/search-service:0.11.1' = if (deployAiFoundry && deploySearchService && aiSearchResourceId == '') {
  name: 'searchServiceAIFoundry'
  params: {
    name: aiFoundrySearchServiceName
    location: _searchServiceLocation
    publicNetworkAccess: _publicNetworkAccess
    networkRuleSet: _applyIpRules ? {
      bypass: 'AzureServices'
      ipRules: _searchIpRules
    } : null
    tags: _tags

    // SKU & capacity (aligned with application search defaults; override for heavier workloads)
    // Using 'standard' SKU for reliable regional capacity availability.
    sku: 'standard'
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'disabled'

    // Identity & Auth: system-assigned MI (AI Foundry project identity gets data-plane roles via AVM)
    managedIdentities: {
      systemAssigned: true
    }

    disableLocalAuth: false
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
  dependsOn: [
    containerEnv!
    // Serialize creation of the two search services to avoid a rare race
    // condition in the Microsoft.Search resource provider where two parallel
    // PUTs against similarly-named services in the same region/subscription
    // can leave the second name "stuck" in the backend namespace cache,
    // producing subsequent "already exists" / "ServiceNameUnavailable" errors
    // even though the service is not visible in ARM and the name appears
    // available to checkNameAvailability.
    searchService!
  ]
}

// Azure AI Speech (SpeechServices)
//////////////////////////////////////////////////////////////////////////
// First-class, optional Speech account. Same network-isolated posture as the
// rest of the AI services in this landing zone — customSubDomainName,
// publicNetworkAccess=Disabled under NI, private endpoint into the existing
// `privatelink.cognitiveservices.azure.com` zone (groupId `account`), and
// system-assigned MI for diagnostic settings / future RBAC scenarios.
//
// PE is created externally via `_peList` (parallel to the search/cosmos
// pattern) so it routes through the same `privateEndpoints` aggregator
// module and reuses the existing private DNS zone — no duplicate zone.
module speechService 'br/public:avm/res/cognitive-services/account:0.13.2' = if (deploySpeechService) {
  name: 'speechService'
  params: {
    name: speechServiceName
    location: _speechServiceLocation
    tags: _tags
    kind: 'SpeechServices'
    sku: speechServiceSku

    // customSubDomainName is required for AAD auth and private endpoints.
    // Pinning it to the account name keeps the FQDN deterministic.
    customSubDomainName: speechServiceName

    publicNetworkAccess: _publicNetworkAccess
    networkAcls: _applyIpRules ? {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: _cognitiveIpRules
    } : {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }

    // Identity for diagnostic settings + future data-plane RBAC scenarios.
    managedIdentities: {
      systemAssigned: true
    }

    // PE is created out-of-module via `_peList` (#35).
    privateEndpoints: []

    diagnosticSettings: _hasEffectiveLaw ? [
      {
        workspaceResourceId: _lawResourceId
      }
    ] : []
  }
}

// Storage Accounts
//////////////////////////////////////////////////////////////////////////

// Azure AI Document Intelligence (FormRecognizer)
//////////////////////////////////////////////////////////////////////////
// Optional Document Intelligence account following the same posture as the
// Speech Service module: AVM cognitive-services/account, publicNetworkAccess
// controlled by _publicNetworkAccess, PE via _peList reusing the existing
// privatelink.cognitiveservices.azure.com zone (no new DNS zone needed).
module documentIntelligence 'modules/document-intelligence.bicep' = if (deployDocumentIntelligence) {
  name: 'documentIntelligence'
  params: {
    name: documentIntelligenceName
    location: _documentIntelligenceLocation
    tags: _tags
    sku: documentIntelligenceSku
    publicNetworkAccess: _publicNetworkAccess
    networkAcls: _applyIpRules ? {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: _cognitiveIpRules
    } : {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    logAnalyticsWorkspaceResourceId: _hasEffectiveLaw ? _lawResourceId : ''
  }
}
// Storage Account
module storageAccount 'br/public:avm/res/storage/storage-account:0.26.2' = if (deployStorageAccount) {
  name: 'storageAccountSolution'
  params: {
    name: storageAccountName
    location: location
    publicNetworkAccess: _publicNetworkAccess
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    requireInfrastructureEncryption: true
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: _storageIpRules
      defaultAction: _applyIpRules ? 'Deny' : 'Allow'
    }
    tags: _tags
    blobServices: {
      automaticSnapshotPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 10
      containerDeleteRetentionPolicyEnabled: true
      containers: [
        for container in storageAccountContainersList: {
          name: container.name
          publicAccess: 'None'
        }
      ]
      deleteRetentionPolicyDays: 7
      deleteRetentionPolicyEnabled: true
      lastAccessTimeTrackingPolicyEnabled: true
    }
  }
}

//////////////////////////////////////////////////////////////////////////
// ROLE ASSIGNMENTS
//////////////////////////////////////////////////////////////////////////

// Role assignments are centralized in this section to make it easier to view all permissions granted in this template.
// Custom modules are used for role assignments since no published AVM module available for this at the time we created this template.

// ---------------------------------------------------------------------------
// Executor role assignments (consolidated into a single array-driven module
// call to reduce compiled ARM template size).
// ---------------------------------------------------------------------------
var _executorRoles = concat(
  deployContainerRegistry ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPush.guid)
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPull.guid)
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: principalType
    }
  ] : [],
  deployKeyVault ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultContributor.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultSecretsOfficer.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: principalType
    }
  ] : [],
  deploySearchService ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchServiceContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchIndexDataContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchIndexDataReader.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: principalType
    }
  ] : [],
  deployStorageAccount ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.StorageBlobDataContributor.guid)
      #disable-next-line BCP318
      resourceId: storageAccount.outputs.resourceId
      principalType: principalType
    }
  ] : [],
  deployAiFoundry ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesOpenAIUser.guid)
      resourceId: aiFoundryAccountResourceId
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesUser.guid)
      resourceId: aiFoundryAccountResourceId
      principalType: principalType
    }
  ] : [],
  deploySpeechService ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesContributor.guid)
      #disable-next-line BCP318
      resourceId: speechService.outputs.resourceId
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesUser.guid)
      #disable-next-line BCP318
      resourceId: speechService.outputs.resourceId
      principalType: principalType
    }
  ] : [],
  deployDocumentIntelligence ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesContributor.guid)
      #disable-next-line BCP318
      resourceId: documentIntelligence.outputs.resourceId
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesUser.guid)
      #disable-next-line BCP318
      resourceId: documentIntelligence.outputs.resourceId
      principalType: principalType
    }
  ] : []
)

module assignExecutorRoles 'modules/security/resource-role-assignment.bicep' = if (deployContainerRegistry || deployKeyVault || deploySearchService || deployStorageAccount || deployAiFoundry || deploySpeechService || deployDocumentIntelligence) {
  name: 'assignExecutorRoles'
  params: {
    name: 'assignExecutorRoles'
    roleAssignments: _executorRoles
  }
}

// Cosmos DB Account - Cosmos DB Built-in Data Contributor -> Executor (data plane, separate module)
module assignCosmosDBCosmosDbBuiltInDataContributorExecutor 'modules/security/cosmos-data-plane-role-assignment.bicep' = if (deployCosmosDb) {
  name: 'assignCosmosDBCosmosDbBuiltInDataContributorExecutor'
  params: {
    #disable-next-line BCP318
    cosmosDbAccountName: cosmosDBAccount.outputs.name
    principalId: principalId
    roleDefinitionGuid: const.roles.CosmosDBBuiltInDataContributor.guid
    scopePath: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccountName}'
  }
}

// Key Vault Service - Key Vault Secrets User -> ContainerApp (per-app loop preserved)
module assignKeyVaultSecretsUserAca 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployKeyVault && contains(app.roles, const.roles.KeyVaultSecretsUser.key)) {
    name: 'assignKeyVaultSecretsUserAca-${app.service_name}'
    params: {
      name: 'assignKeyVaultSecretsUserAca-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.KeyVaultSecretsUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: keyVault.id
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// App Configuration Settings Service - App Configuration Data Reader -> ContainerApp
module assignAppConfigAppConfigurationDataReaderContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployAppConfig && contains(
    app.roles,
    const.roles.AppConfigurationDataReader.key
  )) {
    name: 'assignAppConfigAppConfigurationDataReader-${app.service_name}'
    params: {
      name: 'assignAppConfigAppConfigurationDataReader-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.AppConfigurationDataReader.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: appConfig.id
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// AI Foundry Account - Cognitive Services User -> ContainerApp
module assignAiFoundryAccountCognitiveServicesUserContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployAiFoundry && contains(
    app.roles,
    const.roles.CognitiveServicesUser.key
  )) {
    name: 'assignAIFoundryAccountCognitiveServicesUser-${app.service_name}'
    params: {
      name: 'assignAIFoundryAccountCognitiveServicesUser-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.CognitiveServicesUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          resourceId: aiFoundryAccountResourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// AI Foundry Account - Cognitive Services OpenAI User -> ContainerApp
module assignAIFoundryCogServOAIUserContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployAiFoundry && contains(
    app.roles,
    const.roles.CognitiveServicesOpenAIUser.key
  )) {
    name: 'assignAIFoundryCogServOAIUserContainerApps-${app.service_name}'
    params: {
      name: 'assignAIFoundryCogServOAIUserContainerApps-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.CognitiveServicesOpenAIUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          resourceId: aiFoundryAccountResourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Speech Service - Cognitive Services User -> ContainerApp (#35)
// Granted whenever a container app declares the `CognitiveServicesUser` role
// token in its `roles` array AND `deploySpeechService=true`. Idempotent with
// the AI Foundry assignment of the same role token because the two have
// different `resourceId` scopes.
module assignSpeechCognitiveServicesUserContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deploySpeechService && contains(
    app.roles,
    const.roles.CognitiveServicesUser.key
  )) {
    name: 'assignSpeechCognitiveServicesUser-${app.service_name}'
    params: {
      name: 'assignSpeechCognitiveServicesUser-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.CognitiveServicesUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: speechService.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Document Intelligence - Cognitive Services User -> ContainerApp (#solution)
// Granted whenever a container app declares the `CognitiveServicesUser` role
// token AND `deployDocumentIntelligence=true`. Scoped to the Document
// Intelligence resource so it does not conflict with AI Foundry or Speech
// assignments of the same role.
module assignDocIntelCognitiveServicesUserContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployDocumentIntelligence && contains(
    app.roles,
    const.roles.CognitiveServicesUser.key
  )) {
    name: 'assignDocIntelCogServUser-${app.service_name}'
    params: {
      name: 'assignDocIntelCogServUser-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.CognitiveServicesUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: documentIntelligence.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// AI Foundry Account - Cognitive Services User -> Search Service (for agentic retrieval vectorizers)
module assignAiFoundryAccountCognitiveServicesUserSearch 'modules/security/resource-role-assignment.bicep' = if (deployAiFoundry && deploySearchService) {
  name: 'assignAiFoundryAccountCognitiveServicesUserSearch'
  params: {
    name: 'assignAiFoundryAccountCognitiveServicesUserSearch'
    roleAssignments: [
      {
        #disable-next-line BCP318
        principalId: (_useUAI) ? searchServiceUAI.properties.principalId : searchService.outputs.systemAssignedMIPrincipalId!
        roleDefinitionId: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          const.roles.CognitiveServicesUser.guid
        )
        resourceId: aiFoundryAccountResourceId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// Azure Container Registry Service - AcrPull -> ACR Pull Identity
module assignCrAcrPullContainerApps 'modules/security/resource-role-assignment.bicep' = if (deployContainerApps && deployContainerRegistry) {
    name: 'assignCrAcrPull-acrPullUAI'
    params: {
      name: 'assignCrAcrPull-acrPullUAI'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPull.guid)
          principalId: acrPullUAI.properties.principalId
          #disable-next-line BCP318
          resourceId: containerRegistry.id
          principalType: 'ServicePrincipal'
        }
      ]
    }
}

// Cosmos DB Account - Cosmos DB Built-in Data Contributor -> ContainerApp
module assignCosmosDBCosmosDbBuiltInDataContributorContainerApps 'modules/security/cosmos-data-plane-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployCosmosDb && contains(
    app.roles,
    const.roles.CosmosDBBuiltInDataContributor.key
  )) {
    name: 'assignCosmosDBCosmosDbBuiltInDataContributor-${app.service_name}'
    params: {
      #disable-next-line BCP318
      cosmosDbAccountName: cosmosDBAccount.outputs.name
      #disable-next-line BCP318
      principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
      roleDefinitionGuid: const.roles.CosmosDBBuiltInDataContributor.guid
      scopePath: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccountName}'
    }
  }
]

// Key Vault Service - Key Vault Secrets User -> ContainerApp
module assignKeyVaultKeyVaultSecretsUserContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployKeyVault && contains(app.roles, const.roles.KeyVaultSecretsUser.key)) {
    name: 'assignKeyVaultKeyVaultSecretsUser-${app.service_name}'
    params: {
      name: 'assignKeyVaultKeyVaultSecretsUser-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.KeyVaultSecretsUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: keyVault.id
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Search Service - Search Index Data Reader -> ContainerApp
module assignSearchSearchIndexDataReaderContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deploySearchService && contains(
    app.roles,
    const.roles.SearchIndexDataReader.key
  )) {
    name: 'assignSearchSearchIndexDataReader-${app.service_name}'
    params: {
      name: 'assignSearchSearchIndexDataReader-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.SearchIndexDataReader.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI)  ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: searchService.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Search Service - Search Index Data Contributor -> ContainerApp
module assignSearchSearchIndexDataContributorContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deploySearchService && contains(
    app.roles,
    const.roles.SearchIndexDataContributor.key
  )) {
    name: 'assignSearchSearchIndexDataContributor-${app.service_name}'
    params: {
      name: 'assignSearchSearchIndexDataContributor-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.SearchIndexDataContributor.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId  : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: searchService.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Storage Account - Storage Blob Data Contributor -> ContainerApp
module assignStorageStorageBlobDataContributorAca 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployStorageAccount && contains(
    app.roles,
    const.roles.StorageBlobDataContributor.key
  )) {
    name: 'assignStorageStorageBlobDataContributor-${app.service_name}'
    params: {
      name: 'assignStorageStorageBlobDataContributor-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.StorageBlobDataContributor.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: storageAccount.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Storage Account - Storage Blob Data Reader -> ContainerApp
module assignStorageStorageBlobDataReaderAca 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployStorageAccount && contains(
    app.roles,
    const.roles.StorageBlobDataReader.key
  )) {
    name: 'assignStorageStorageBlobDataReaderAca-${app.service_name}'
    params: {
      name: 'assignStorageStorageBlobDataReaderAca-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.StorageBlobDataReader.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI)  ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: storageAccount.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Storage Account - Storage Blob Data Delegator -> ContainerApp
module assignStorageStorageBlobDataDelegatorAca 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployStorageAccount && contains(
    app.roles,
    const.roles.StorageBlobDelegator.key
  )) {
    name: 'assignStorageStorageBlobDataDelegatorAca-${app.service_name}'
    params: {
      name: 'assignStorageStorageBlobDataDelegatorAca-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.StorageBlobDelegator.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI)  ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: storageAccount.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Storage Account - Storage Blob Data Reader -> Search Service
module assignStorageStorageBlobDataReaderSearch 'modules/security/resource-role-assignment.bicep' = if (deployStorageAccount && deploySearchService) {
  name: 'assignStorageStorageBlobDataReaderSearch'
  params: {
    name: 'assignStorageStorageBlobDataReaderSearch'
    roleAssignments: [
      {
        #disable-next-line BCP318
        principalId: (_useUAI) ? searchServiceUAI.properties.principalId : searchService.outputs.systemAssignedMIPrincipalId!
        roleDefinitionId: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          const.roles.StorageBlobDataReader.guid
        )
        #disable-next-line BCP318
        resourceId: storageAccount.outputs.resourceId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// Search Service - Search Index Data Reader -> AiFoundryProject
module assignSearchSearchIndexDataReaderAIFoundryProject 'modules/security/resource-role-assignment.bicep' = if (deployAiFoundry && deploySearchService) {
  name: 'assignSearchSearchIndexDataReaderAIFoundryProject'
  params: {
    name: 'assignSearchSearchIndexDataReaderAIFoundryProject'
    roleAssignments: [
      {
        principalId: aiFoundry!.outputs.aiProjectPrincipalId
        roleDefinitionId: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          const.roles.SearchIndexDataReader.guid
        )
        #disable-next-line BCP318
        resourceId: searchService.outputs.resourceId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// NOTE: Search Service Contributor for the AI Foundry Project identity on the
// Search service is already created by the AVM AI Foundry module (avm/ptn/ai-ml/ai-foundry)
// when aiSearchConfiguration is provided. Creating it again here causes a
// RoleAssignmentExists conflict because both produce the same deterministic GUID.
// Intentionally omitted.

// Storage Account - Storage Blob Data Reader -> AiFoundry Project
module assignStorageStorageBlobDataReaderAIFoundryProject 'modules/security/resource-role-assignment.bicep' = if (deployAiFoundry && deployStorageAccount) {
  name: 'assignStorageStorageBlobDataReaderAIFoundryProject'
  params: {
    name: 'assignStorageStorageBlobDataReaderAIFoundryProject'
    roleAssignments: [
      {
        principalId: aiFoundry!.outputs.aiProjectPrincipalId
        roleDefinitionId: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          const.roles.StorageBlobDataReader.guid
        )
        #disable-next-line BCP318
        resourceId: storageAccount.outputs.resourceId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

//////////////////////////////////////////////////////////////////////////
// App Configuration Settings Service
//////////////////////////////////////////////////////////////////////////

// App Configuration Store
//////////////////////////////////////////////////////////////////////////

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = if (deployAppConfig) {
  name: appConfigName
  location: location
  tags: _tags
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dataPlaneProxy: {
      authenticationMode: 'Pass-through'
      privateLinkDelegation: _networkIsolation ? 'Enabled' : 'Disabled'
    }
    // Note: App Configuration does not expose `networkAcls.ipRules` like the
    // other workload services, so `allowedIpRanges` is intentionally ignored
    // here. The public surface still tracks `_publicNetworkAccess` so the
    // service follows the same Enabled/Disabled logic as the rest of the stack.
    publicNetworkAccess: _publicNetworkAccess
    disableLocalAuth: false
  }
}

resource appConfigDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAppConfig) {
  #disable-next-line use-resource-id-functions
  name: guid(appConfig.id, principalId, const.roles.AppConfigurationDataOwner.guid)
  scope: appConfig
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AppConfigurationDataOwner.guid)
  }
}

// prepare the container apps settings for the app configuration store
module containerAppsSettings 'modules/container-apps/container-apps-list.bicep' = if (deployContainerApps) {
  name: 'containerAppsSettings'
  params: {
    appConfigLabel: appConfigLabel
    containerAppsList: [
      for i in range(0, length(containerAppsList)): {
        #disable-next-line BCP318
        name: containerApps[i].outputs.name
        serviceName: containerAppsList[i].service_name
        canonical_name: containerAppsList[i].canonical_name
        #disable-next-line BCP318
        principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
        #disable-next-line BCP318
        fqdn: containerApps[i].outputs.fqdn
      }
    ]
  }
}

// Optional Public Ingress (#49) — Application Gateway WAF v2 in front of the
// internal Container Apps environment. See `modules/networking/public-ingress.bicep`
// and the README "Optional Public Ingress" section for the runbook.
module publicIngressM 'modules/networking/public-ingress.bicep' = if (_publicIngressEnabled) {
  name: 'publicIngressDeployment'
  params: {
    namePrefix: 'agw-${resourceToken}'
    location: location
    tags: _tags
    #disable-next-line BCP318
    appGatewaySubnetResourceId: '${virtualNetworkResourceId}/subnets/${azureAppGatewaySubnetName}'
    logAnalyticsWorkspaceResourceId: _lawResourceId
    #disable-next-line BCP318
    backendAppFqdn: containerApps[_publicIngressBackendIndex].outputs.fqdn
    useZoneRedundancy: useZoneRedundancy
    wafMode: publicIngress.?wafMode ?? 'Prevention'
    wafCustomRules: publicIngress.?wafCustomRules ?? []
    capacity: publicIngress.?capacity ?? { minCapacity: 0, maxCapacity: 2 }
    sslPolicy: publicIngress.?sslPolicy ?? {}
    sslCertSecretId: publicIngress.?sslCertSecretId ?? ''
    frontendHostName: publicIngress.?frontendHostName ?? ''
    keyVaultResourceId: deployKeyVault ? keyVault.id : ''
    keyVaultName: deployKeyVault ? keyVaultName : ''
  }
}

// prepare the model deployment names for the app configuration store
var _modelDeploymentNamesSettings = [
  for modelDeployment in modelDeploymentList: {
    name: modelDeployment.canonical_name
    value: modelDeployment.name
    label: appConfigLabel
    contentType: 'text/plain'
  }
]

// prepare the database container names for the app configuration store
var _databaseContainerNamesSettings = [
  for databaseContainer in databaseContainersList: {
    name: databaseContainer.canonical_name
    value: databaseContainer.name
    label: appConfigLabel
    contentType: 'text/plain'
  }
]

// prepare the storage container names for the app configuration store
var _storageContainerNamesSettings = [
  for storageContainer in storageAccountContainersList: {
    name: storageContainer.canonical_name
    value: storageContainer.name
    label: appConfigLabel
    contentType: 'text/plain'
  }
]

var _modelDeploymentSettings = [
  for modelDeployment in modelDeploymentList: { 
    canonical_name: modelDeployment.canonical_name 
    capacity: modelDeployment.sku.capacity          
    model: modelDeployment.model.name                  
    modelFormat: modelDeployment.model.format          
    name: modelDeployment.name
    version: modelDeployment.model.version         
    apiVersion: modelDeployment.?apiVersion ?? '2025-01-01-preview' 
    endpoint: 'https://${aiFoundryAccountName}.openai.azure.com/' 
  }
]

// Populate App Configuration store with Container App API keys (only when useAPIKeys is true).
module appConfigKeyVaultPopulate 'modules/app-configuration/app-configuration.bicep' = if (deployAppConfig && deployKeyVault && _useCAppAPIKey) {
  name: 'appConfigKeyVaultPopulate'
  params: {
    #disable-next-line BCP318
    storeName: appConfig.name
    keyValues:  [ 
      for app in containerAppsList: {
            name: '${app.canonical_name}_APIKEY'
            #disable-next-line BCP318
            value: '{"uri":"${keyVault.properties.vaultUri}secrets/${replace(app.canonical_name, '_', '-')}-APIKEY"}'
            label: appConfigLabel
            contentType: 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
      }
    ]
  }
}

module cosmosConfigKeyVaultPopulate 'modules/app-configuration/app-configuration.bicep' = if (deployCosmosDb && deployAppConfig && !_networkIsolation) {
  name: 'cosmosConfigKeyVaultPopulate'
  params: {
    #disable-next-line BCP318
    storeName: appConfig.name
    keyValues: concat(
      [
        #disable-next-line BCP318
      { name: 'COSMOS_DB_ACCOUNT_RESOURCE_ID', value: cosmosDBAccount.outputs.resourceId, label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'COSMOS_DB_ENDPOINT',              value: cosmosDBAccount.outputs.endpoint,            label: appConfigLabel, contentType: 'text/plain' }
      ]
    )
  }
}

module appConfigPopulate 'modules/app-configuration/app-configuration.bicep' = if (deployAppConfig && !_networkIsolation) {
  name: 'appConfigPopulate'
  params: {
    #disable-next-line BCP318
    storeName: appConfig.name
    keyValues: concat(
      #disable-next-line BCP318
      deployContainerApps ? containerAppsSettings.outputs.containerAppsEndpoints : [],
      #disable-next-line BCP318
      deployContainerApps ? containerAppsSettings.outputs.containerAppsName : [],
      _modelDeploymentNamesSettings,
      _databaseContainerNamesSettings,
      _storageContainerNamesSettings,
      [
        // ── General / Deployment ─────────────────────────────────────────────
      { name: 'AZURE_TENANT_ID',     value: tenant().tenantId,                      label: appConfigLabel, contentType: 'text/plain' }
      { name: 'SUBSCRIPTION_ID',     value: subscription().subscriptionId,          label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AZURE_RESOURCE_GROUP', value: resourceGroup().name,                  label: appConfigLabel, contentType: 'text/plain' }
      { name: 'LOCATION',            value: location,                               label: appConfigLabel, contentType: 'text/plain' }
      { name: 'ENVIRONMENT_NAME',    value: environmentName,                        label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOYMENT_NAME',     value: deployment().name,                      label: appConfigLabel, contentType: 'text/plain' }
      { name: 'RESOURCE_TOKEN',      value: resourceToken,                          label: appConfigLabel, contentType: 'text/plain' }
      { name: 'ENABLE_AGENTIC_RETRIEVAL', value: toLower(string(enableAgenticRetrieval)), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'NETWORK_ISOLATION',   value: toLower(string(_networkIsolation)),     label: appConfigLabel, contentType: 'text/plain' }
      { name: 'USE_UAI',             value: string(_useUAI),                        label: appConfigLabel, contentType: 'text/plain' }
      { name: 'LOG_LEVEL',           value: 'INFO',                                 label: appConfigLabel, contentType: 'text/plain' }
      { name: 'ENABLE_CONSOLE_LOGGING', value: 'true',                              label: appConfigLabel, contentType: 'text/plain' }
      { name: 'RELEASE',     value: _manifest.tag,                      label: appConfigLabel, contentType: 'text/plain' }
      { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: _appInsightsConnectionString,   label: appConfigLabel, contentType: 'text/plain' }
      { name: 'APPLICATIONINSIGHTS__INSTRUMENTATIONKEY', value: _appInsightsInstrumentationKey, label: appConfigLabel, contentType: 'text/plain' }

      //── Resource IDs ─────────────────────────────────────────────────────
      #disable-next-line BCP318
      { name: 'KEY_VAULT_RESOURCE_ID', value: deployKeyVault ? keyVault.id : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'STORAGE_ACCOUNT_RESOURCE_ID', value: deployStorageAccount ? storageAccount.outputs.resourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'APP_INSIGHTS_RESOURCE_ID', value: _appInsightsResourceId, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'LOG_ANALYTICS_RESOURCE_ID', value: _lawResourceId, label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'CONTAINER_ENV_RESOURCE_ID', value: deployContainerEnv ? containerEnv.id : '', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_ACCOUNT_RESOURCE_ID', value: (deployAiFoundry) ? aiFoundryAccountResourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_PROJECT_RESOURCE_ID', value: (deployAiFoundry) ? aiFoundryProjectResourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      // { name: 'AI_FOUNDRY_PROJECT_WORKSPACE_ID', value: (deployAiFoundry) ? aiFoundryFormatProjectWorkspaceId!.outputs.projectWorkspaceIdGuid : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'SEARCH_SERVICE_UAI_RESOURCE_ID', value: (deploySearchService && _useUAI) ? searchServiceUAI.id : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'SEARCH_SERVICE_RESOURCE_ID', value: deploySearchService ? searchService.outputs.resourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'AZURE_SPEECH_RESOURCE_ID', value: deploySpeechService ? speechService.outputs.resourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      
      // ── Resource Names ───────────────────────────────────────────────────
      { name: 'AI_FOUNDRY_ACCOUNT_NAME', value: aiFoundryAccountName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_PROJECT_NAME', value: aiFoundryProjectName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_STORAGE_ACCOUNT_NAME', value: aiFoundryStorageAccountName, label: appConfigLabel, contentType: 'text/plain'}
      { name: 'APP_CONFIG_NAME', value: appConfigName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'APP_INSIGHTS_NAME', value: appInsightsName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'CONTAINER_ENV_NAME', value: containerEnvName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'CONTAINER_REGISTRY_NAME', value: containerRegistryName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'CONTAINER_REGISTRY_LOGIN_SERVER', value: '${containerRegistryName}.azurecr.io', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DATABASE_ACCOUNT_NAME', value: dbAccountName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DATABASE_NAME', value: dbDatabaseName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'SEARCH_SERVICE_NAME', value: searchServiceName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AZURE_SPEECH_RESOURCE_NAME', value: deploySpeechService ? speechServiceName : '', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AZURE_SPEECH_REGION', value: deploySpeechService ? _speechServiceLocation : '', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'STORAGE_ACCOUNT_NAME', value: storageAccountName, label: appConfigLabel, contentType: 'text/plain' }

      // ── Feature flagging ─────────────────────────────────────────────────
      { name: 'DEPLOY_APP_CONFIG', value: string(deployAppConfig), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_KEY_VAULT', value: string(deployKeyVault), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_LOG_ANALYTICS', value: string(deployLogAnalytics), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_APP_INSIGHTS', value: string(deployAppInsights), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_SEARCH_SERVICE', value: string(deploySearchService), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_SPEECH_SERVICE', value: string(deploySpeechService), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_STORAGE_ACCOUNT', value: string(deployStorageAccount), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_COSMOS_DB', value: string(deployCosmosDb), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_CONTAINER_APPS', value: string(deployContainerApps), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_CONTAINER_REGISTRY', value: string(deployContainerRegistry), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_CONTAINER_ENV', value: string(deployContainerEnv), label: appConfigLabel, contentType: 'text/plain' }

      // ── Endpoints / URIs ──────────────────────────────────────────────────
      #disable-next-line BCP318
      { name: 'KEY_VAULT_URI',                   value: deployKeyVault ? keyVault.properties.vaultUri : '',                        label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'STORAGE_BLOB_ENDPOINT',           value: deployStorageAccount ? storageAccount.outputs.primaryBlobEndpoint : '',  label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_ACCOUNT_ENDPOINT',     value: (deployAiFoundry) ? aiFoundryAccountEndpoint : '', label: appConfigLabel, contentType: 'text/plain' }      
      { name: 'AI_FOUNDRY_PROJECT_ENDPOINT',     value: (deployAiFoundry) ? aiFoundryProjectEndpoint : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'SEARCH_SERVICE_QUERY_ENDPOINT',   value: deploySearchService ? searchService.outputs.endpoint : '',              label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'AZURE_SPEECH_ENDPOINT', value: deploySpeechService ? speechService.outputs.endpoint : '', label: appConfigLabel, contentType: 'text/plain' }

      // ── Connections ───────────────────────────────────────────────────────
      #disable-next-line BCP318
      { name: 'SEARCH_CONNECTION_ID', value: deploySearchService && deployAiFoundry ? aiFoundryConnectionSearch.outputs.searchConnectionId : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'BING_CONNECTION_ID', value: deployGroundingWithBing && deployAiFoundry ? bingSearchConnection!.outputs.bingConnectionId : '', label: appConfigLabel, contentType: 'text/plain' }

      //── Managed Identity Principals ───────────────────────────────────────
      #disable-next-line BCP318
      { name: 'CONTAINER_ENV_PRINCIPAL_ID', value: deployContainerEnv ? ((_useUAI) ? containerEnvUAI.properties.principalId : (containerEnv.?identity.?principalId ?? '')) : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'SEARCH_SERVICE_PRINCIPAL_ID', value: deploySearchService ? ((_useUAI) ? searchServiceUAI.properties.principalId : searchService.outputs.systemAssignedMIPrincipalId!) : '', label: appConfigLabel, contentType: 'text/plain' }

      // ── Container Apps List & Model Deployments ────────────────────────────
      #disable-next-line BCP318
      { name: 'CONTAINER_APPS', value: deployContainerApps ? string(containerAppsSettings.outputs.containerAppsList) : '[]', label: appConfigLabel, contentType: 'application/json' }
      { name: 'MODEL_DEPLOYMENTS', value: string(_modelDeploymentSettings), label: appConfigLabel, contentType: 'application/json' }

    ]
    )
  }
}

//////////////////////////////////////////////////////////////////////////
// OUTPUTS
//////////////////////////////////////////////////////////////////////////

// ──────────────────────────────────────────────────────────────────────
// General / Deployment
// ──────────────────────────────────────────────────────────────────────
output TENANT_ID string = tenant().tenantId
output SUBSCRIPTION_ID string = subscription().subscriptionId
output AZURE_RESOURCE_GROUP string = resourceGroup().name
output LOCATION string = location
output ENVIRONMENT_NAME string = environmentName
output DEPLOYMENT_NAME string = deployment().name
output RESOURCE_TOKEN string = resourceToken
output NETWORK_ISOLATION bool = _networkIsolation
output USE_UAI bool = _useUAI
output USE_CAPP_API_KEY bool = _useCAppAPIKey
output RELEASE string = _manifest.tag

// ──────────────────────────────────────────────────────────────────────
// Feature flagging
// ──────────────────────────────────────────────────────────────────────
output DEPLOY_APP_CONFIG bool = deployAppConfig
output DEPLOY_SOFTWARE bool = deploySoftware
output DEPLOY_KEY_VAULT bool = deployKeyVault
output DEPLOY_LOG_ANALYTICS bool = deployLogAnalytics
output DEPLOY_APP_INSIGHTS bool = deployAppInsights
output DEPLOY_SEARCH_SERVICE bool = deploySearchService
output DEPLOY_SPEECH_SERVICE bool = deploySpeechService
output DEPLOY_STORAGE_ACCOUNT bool = deployStorageAccount
output DEPLOY_COSMOS_DB bool = deployCosmosDb
output DEPLOY_CONTAINER_APPS bool = deployContainerApps
output DEPLOY_CONTAINER_REGISTRY bool = deployContainerRegistry
output DEPLOY_CONTAINER_ENV bool = deployContainerEnv
output DEPLOY_VM_KEY_VAULT bool = deployVmKeyVault

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = '${containerRegistryName}.azurecr.io'

@description('Name of the ACR Task agent pool when deployed. Empty when not deployed.')
output ACR_TASK_AGENT_POOL string = _deployAcrTaskAgentPool ? acrTaskAgentPoolName : ''

// ──────────────────────────────────────────────────────────────────────
// Endpoints / URIs
// ──────────────────────────────────────────────────────────────────────
#disable-next-line BCP318
output APP_CONFIG_ENDPOINT string = deployAppConfig ? appConfig.properties.endpoint : ''

// Azure AI Speech (#35)
#disable-next-line BCP318
output AZURE_SPEECH_RESOURCE_ID string = deploySpeechService ? speechService.outputs.resourceId : ''
#disable-next-line BCP318
output AZURE_SPEECH_ENDPOINT string = deploySpeechService ? speechService.outputs.endpoint : ''
output AZURE_SPEECH_REGION string = deploySpeechService ? _speechServiceLocation : ''
output AZURE_SPEECH_RESOURCE_NAME string = deploySpeechService ? speechServiceName : ''

// ──────────────────────────────────────────────────────────────────────
// Public Ingress (#49) — surface the gateway for downstream automation
// (DNS A record, NSG audit, health checks). Empty when not deployed.
// ──────────────────────────────────────────────────────────────────────
output PUBLIC_INGRESS_ENABLED bool = _publicIngressEnabled
#disable-next-line BCP318
output PUBLIC_INGRESS_PUBLIC_IP string = _publicIngressEnabled ? publicIngressM!.outputs.publicIp : ''
#disable-next-line BCP318
output PUBLIC_INGRESS_PUBLIC_IP_RESOURCE_ID string = _publicIngressEnabled ? publicIngressM!.outputs.publicIpResourceId : ''
#disable-next-line BCP318
output PUBLIC_INGRESS_GATEWAY_RESOURCE_ID string = _publicIngressEnabled ? publicIngressM!.outputs.gatewayResourceId : ''
#disable-next-line BCP318
output PUBLIC_INGRESS_NSG_RESOURCE_ID string = _publicIngressEnabled ? appGwNsg!.outputs.id : ''
#disable-next-line BCP318
output PUBLIC_INGRESS_WAF_POLICY_RESOURCE_ID string = _publicIngressEnabled ? publicIngressM!.outputs.wafPolicyResourceId : ''
#disable-next-line BCP318
output PUBLIC_INGRESS_IDENTITY_PRINCIPAL_ID string = _publicIngressEnabled ? publicIngressM!.outputs.identityPrincipalId : ''
#disable-next-line BCP318
output PUBLIC_INGRESS_LIVE bool = _publicIngressEnabled ? publicIngressM!.outputs.liveMode : false

// Landing-zone outputs that the public-ingress module (or external consumers)
// depend on. Surfacing these unconditionally aligns with #49.
output APP_GATEWAY_SUBNET_RESOURCE_ID string = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${azureAppGatewaySubnetName}' : ''
output VNET_RESOURCE_ID string = virtualNetworkResourceId
#disable-next-line BCP318
output KEY_VAULT_RESOURCE_ID string = deployKeyVault ? keyVault.id : ''
output KEY_VAULT_NAME string = deployKeyVault ? keyVaultName : ''
#disable-next-line BCP318
output LOG_ANALYTICS_RESOURCE_ID string = _lawResourceId
output APP_INSIGHTS_RESOURCE_ID string = _appInsightsResourceId
output OBSERVABILITY_MIXED_WORKSPACES_ALLOWED bool = allowMixedObservabilityWorkspaces
#disable-next-line BCP318
output CONTAINER_APP_INTERNAL_FQDN string = (deployContainerApps && length(containerAppsList) > 0) ? containerApps[_publicIngressBackendIndex].outputs.fqdn : ''

// ──────────────────────────────────────────────────────────────────────
// Solution-specific outputs (multi-agent home banking assistant)
// ──────────────────────────────────────────────────────────────────────

// Document Intelligence
#disable-next-line BCP318
output DOCUMENT_INTELLIGENCE_NAME string = deployDocumentIntelligence ? documentIntelligence.outputs.name : ''
#disable-next-line BCP318
output DOCUMENT_INTELLIGENCE_ENDPOINT string = deployDocumentIntelligence ? documentIntelligence.outputs.endpoint : ''

// AI Foundry OpenAI endpoint (for AZURE_OPENAI_ENDPOINT env var)
output AI_FOUNDRY_OPENAI_ENDPOINT string = deployAiFoundry ? 'https://${aiFoundryAccountName}.openai.azure.com/' : ''

// Storage
#disable-next-line BCP318
output STORAGE_ACCOUNT_NAME string = deployStorageAccount ? storageAccount.outputs.name : ''

// Cosmos DB
#disable-next-line BCP318
output COSMOS_DB_ENDPOINT string = deployCosmosDb ? cosmosDBAccount.outputs.endpoint : ''

// Application Insights connection string
output APPLICATIONINSIGHTS_CONNECTION_STRING string = _appInsightsConnectionString

// Container App FQDNs (resolved by canonical_name — index must match containerAppsList order)
// backend=0, account=1, transaction=2, payment=3, web=4
#disable-next-line BCP318
output BACKEND_APP_INTERNAL_FQDN string = (deployContainerApps && length(containerAppsList) > 0) ? 'https://${containerApps[0].outputs.fqdn}' : ''
#disable-next-line BCP318
output BACKEND_APP_EXTERNAL_FQDN string = (deployContainerApps && length(containerAppsList) > 0) ? 'https://${containerApps[0].outputs.fqdn}' : ''
#disable-next-line BCP318
output ACCOUNT_APP_INTERNAL_FQDN string = (deployContainerApps && length(containerAppsList) > 1) ? 'https://${containerApps[1].outputs.fqdn}' : ''
#disable-next-line BCP318
output TRANSACTION_APP_INTERNAL_FQDN string = (deployContainerApps && length(containerAppsList) > 2) ? 'https://${containerApps[2].outputs.fqdn}' : ''
#disable-next-line BCP318
output PAYMENT_APP_INTERNAL_FQDN string = (deployContainerApps && length(containerAppsList) > 3) ? 'https://${containerApps[3].outputs.fqdn}' : ''
#disable-next-line BCP318
output WEB_APP_INTERNAL_FQDN string = (deployContainerApps && length(containerAppsList) > 4) ? 'https://${containerApps[4].outputs.fqdn}' : ''

// Jumpbox VM info — required by hooks/scripts/deploy-via-jumpbox.ps1
output VM_NAME string = _deployJumpbox ? _vmName : ''
#disable-next-line BCP318
output VM_RESOURCE_ID string = _deployJumpbox ? testVm.outputs.resourceId : ''
output BASTION_NAME string = _deployBastion ? '${const.abbrs.security.bastion}testvm-${resourceToken}' : ''

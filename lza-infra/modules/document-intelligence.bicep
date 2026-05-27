// ============================================================================
// Document Intelligence (FormRecognizer) Module
// Follows the same network-isolated posture as the Speech Service in the
// landing zone: AVM cognitive-services/account, privatelink.cognitiveservices.azure.com
// DNS zone (already provisioned), system-assigned MI for diagnostics, and
// PE created via the parent _peList aggregator.
// ============================================================================

@description('Resource name for the Document Intelligence account.')
param name string

@description('Azure region where Document Intelligence will be created. Constrained to eastus, westus2, westeurope for FormRecognizer.')
@allowed(['eastus', 'westus2', 'westeurope'])
param location string = 'eastus'

@description('SKU for the Document Intelligence account.')
@allowed(['F0', 'S0'])
param sku string = 'S0'

@description('Public network access setting. Disable under network isolation.')
param publicNetworkAccess string = 'Enabled'

@description('Network ACLs for IP allow-list support when publicNetworkAccess is Enabled.')
param networkAcls object = {
  defaultAction: 'Allow'
  bypass: 'AzureServices'
}

@description('Resource ID of the Log Analytics workspace for diagnostic settings. Empty = skip diagnostics.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Tags to apply to the resource.')
param tags object = {}

// ─── Resource ───────────────────────────────────────────────────────────────
module documentIntelligence 'br/public:avm/res/cognitive-services/account:0.13.2' = {
  name: 'documentIntelligenceDeployment'
  params: {
    name: name
    location: location
    tags: tags
    kind: 'FormRecognizer'
    sku: sku

    // customSubDomainName is required for AAD auth and private endpoints.
    customSubDomainName: name

    publicNetworkAccess: publicNetworkAccess
    networkAcls: networkAcls

    // System-assigned identity for diagnostic settings.
    managedIdentities: {
      systemAssigned: true
    }

    // PE is created out-of-module via _peList in main.bicep.
    privateEndpoints: []

    diagnosticSettings: !empty(logAnalyticsWorkspaceResourceId) ? [
      {
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ] : []
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────
@description('Resource name of the Document Intelligence account.')
output name string = documentIntelligence.outputs.name

@description('Resource ID of the Document Intelligence account.')
output resourceId string = documentIntelligence.outputs.resourceId

@description('Endpoint of the Document Intelligence account.')
output endpoint string = documentIntelligence.outputs.endpoint

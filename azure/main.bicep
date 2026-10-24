targetScope = 'resourceGroup'

@minLength(3)
@maxLength(3)
param clusters array
param kubernetesVersion string
param operatorCidr string
param operatorObjectId string
param runId string
param expiresAt string

var tags = {
  project: 'managed-container-platform'
  runId: runId
  expiresAt: expiresAt
}
var suffix = uniqueString(resourceGroup().id)
var hubLocation = clusters[0].location

resource egress 'Microsoft.Network/publicIPAddresses@2024-05-01' = [for cluster in clusters: {
  name: 'egress-${cluster.name}'
  location: cluster.location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}]

var allowedRanges = [
  operatorCidr
  '${egress[0].properties.ipAddress}/32'
  '${egress[1].properties.ipAddress}/32'
  '${egress[2].properties.ipAddress}/32'
]

resource controlIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for cluster in clusters: {
  name: 'control-${cluster.name}'
  location: cluster.location
  tags: tags
}]

resource outboundAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (cluster, i) in clusters: {
  name: guid(egress[i].id, controlIdentity[i].id, 'network')
  scope: egress[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
    principalId: controlIdentity[i].properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'mcp${suffix}'
  location: hubLocation
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource aks 'Microsoft.ContainerService/managedClusters@2025-10-01' = [for (cluster, i) in clusters: {
  name: 'platform-${cluster.name}'
  location: cluster.location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${controlIdentity[i].id}': {} }
  }
  dependsOn: [outboundAccess[i]]
  sku: { name: 'Base', tier: 'Free' }
  properties: {
    dnsPrefix: 'mcp-${cluster.name}-${suffix}'
    kubernetesVersion: kubernetesVersion
    enableRBAC: true
    nodeResourceGroup: '${resourceGroup().name}-nodes-${cluster.name}'
    apiServerAccessProfile: { authorizedIPRanges: allowedRanges }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    autoUpgradeProfile: { upgradeChannel: 'none', nodeOSUpgradeChannel: 'None' }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        // One node is a temporary dev/test profile, without availability claims.
        count: 1
        vmSize: cluster.vmSize
        type: 'VirtualMachineScaleSets'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        osDiskSizeGB: 64
        osDiskType: 'Managed'
        maxPods: 60
        enableAutoScaling: false
        enableNodePublicIP: false
        securityProfile: { sshAccess: 'Disabled' }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      loadBalancerProfile: { outboundIPs: { publicIPs: [{ id: egress[i].id }] } }
    }
  }
}]

resource imagePull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (cluster, i) in clusters: {
  name: guid(registry.id, aks[i].id, 'AcrPull')
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: aks[i].properties.identityProfile!.kubeletidentity.objectId!
    principalType: 'ServicePrincipal'
  }
}]

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'identity-probe'
  location: hubLocation
  tags: tags
}

resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [for (cluster, i) in clusters: if (cluster.name != 'hub') {
  parent: identity
  name: cluster.name
  properties: {
    issuer: aks[i].properties.oidcIssuerProfile!.issuerURL!
    subject: 'system:serviceaccount:platform-identity:bound'
    audiences: ['api://AzureADTokenExchange']
  }
}]

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'mcp-${suffix}'
  location: hubLocation
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    accessPolicies: []
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      ipRules: map(allowedRanges, cidr => { value: cidr })
      virtualNetworkRules: []
    }
  }
}

resource probeAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, identity.id, 'probe-read')
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource operatorAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, operatorObjectId, 'seed-sentinel')
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: operatorObjectId
    principalType: 'User'
  }
}

output registryName string = registry.name
output registryServer string = registry.properties.loginServer
output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri!
output identityClientId string = identity.properties.clientId
output identityTenantId string = tenant().tenantId
output clusterIds array = [for i in range(0, length(clusters)): aks[i].id]

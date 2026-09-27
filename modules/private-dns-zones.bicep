// Private DNS zones (created only when missing) and their links to the customer virtual network.
// Deployed at the scope of the private DNS zone resource group.
targetScope = 'resourceGroup'

@description('Private DNS zones that do not exist yet and must be created.')
param zonesToCreate array = []

@description('Private DNS zones (existing or created here) that must be linked to the virtual network.')
param zonesToLink array = []

@description('Resource ID of the customer virtual network.')
param virtualNetworkId string

@description('Name of the virtual network link.')
param linkName string

@description('Tags to apply to new zones and links.')
param tags object = {}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = [for name in zonesToCreate: {
  name: name
  location: 'global'
  tags: tags
}]

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for name in zonesToLink: {
  name: '${name}/${linkName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    // Fall back to public DNS for names missing from the zone, so other private-linked resources keep resolving.
    resolutionPolicy: 'NxDomainRedirect'
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
  dependsOn: [
    zone
  ]
}]

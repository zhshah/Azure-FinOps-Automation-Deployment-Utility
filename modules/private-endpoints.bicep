// Private endpoints for FinOps hub resources in a customer-supplied subnet.
// Deployed at the scope of the private endpoint resource group (must be in the VNet subscription).
targetScope = 'resourceGroup'

@description('Azure region of the virtual network. Private endpoints must be in the same region as their virtual network.')
param location string

@description('Resource ID of the subnet that hosts the private endpoints.')
param subnetId string

@description('Private endpoints to create. Each item: { name, privateLinkServiceId, groupId, privateDnsZoneIds[] }.')
param privateEndpoints array

@description('Tags to apply to the private endpoints.')
param tags object = {}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = [for ep in privateEndpoints: {
  name: ep.name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    customNetworkInterfaceName: '${ep.name}-nic'
    privateLinkServiceConnections: [
      {
        name: ep.name
        properties: {
          privateLinkServiceId: ep.privateLinkServiceId
          groupIds: [
            ep.groupId
          ]
        }
      }
    ]
  }
}]

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (ep, i) in privateEndpoints: if (!empty(ep.privateDnsZoneIds)) {
  parent: privateEndpoint[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for zoneId in ep.privateDnsZoneIds: {
      name: replace(last(split(zoneId, '/')), '.', '-')
      properties: {
        privateDnsZoneId: zoneId
      }
    }]
  }
}]

output privateEndpointIds array = [for (ep, i) in privateEndpoints: privateEndpoint[i].id]

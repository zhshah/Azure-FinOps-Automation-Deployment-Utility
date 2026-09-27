# Sample parameters for an unattended run of Deploy-FinOpsHub-V3-Fabric.ps1.
#
# 1. Copy this file to customer.local.psd1 (files named *.local.psd1 are ignored by git).
# 2. Replace the example values. The keys are the script's parameter names
#    (see: Get-Help ./Deploy-FinOpsHub-V3-Fabric.ps1 -Full).
# 3. Run:
#      $p = Import-PowerShellDataFile ./customer.local.psd1
#      ./Deploy-FinOpsHub-V3-Fabric.ps1 @p
@{
    # FinOps hub and Fabric capacity. Both use this region, which needs Fabric capacity quota.
    SubscriptionId                  = '00000000-0000-0000-0000-000000000000'
    ResourceGroupName               = 'rg-finops-hub'
    Location                        = 'swedencentral'
    FabricCapacitySku               = 'F8'

    # Existing virtual network and subnet (no delegation, 8 or more free IP addresses) for the private endpoints.
    VirtualNetworkSubscriptionId    = '00000000-0000-0000-0000-000000000000'
    VirtualNetworkResourceGroupName = 'rg-network'
    VirtualNetworkName              = 'vnet-hub'
    PrivateEndpointSubnetName       = 'snet-private-endpoints'

    # Existing resource group that holds (or will hold) the private DNS zones, for example in a connectivity subscription.
    # Remove these two lines to use the virtual network's resource group, or replace them with: SkipPrivateDnsZones = $true
    PrivateDnsZoneSubscriptionId    = '00000000-0000-0000-0000-000000000000'
    PrivateDnsZoneResourceGroupName = 'rg-private-dns'

    # Entra ID object IDs of the users or groups that may open the dashboard (Viewer on the Fabric workspace).
    # FabricViewers                 = @('00000000-0000-0000-0000-000000000000')

    # Tags for the resource groups and every resource the script creates.
    Tags                            = @{ Workload = 'FinOps'; Environment = 'Production' }
}

// Outgoing connection

locals {
  vpn_gateway_id = data.terraform_remote_state.vwan.outputs.vpn_gateway.id

  nat_rules = { for rule in var.nat_rules :
    rule.name => {
      properties = {
        mode             = lookup({ ingress = "IngressSnat", egress = "EgressSnat" }, rule.mode)
        type             = "Static"
        internalMappings = [for address_space in rule.mappings[*].internal : { addressSpace = address_space }]
        externalMappings = [for address_space in rule.mappings[*].external : { addressSpace = address_space }]
      }
    }
  }

  ingress_mappings = { for mapping in flatten([for rule in var.nat_rules[*] : rule if rule.mode == "ingress"][*].mappings[*]) :
    (mapping.internal) => mapping.external
  }

  // egress_mappings = { for mapping in flatten([for rule in var.nat_rules[*] : rule if rule.mode == "egress"][*].mappings[*]) :
  //   (mapping.internal) => mapping.external
  // }

  egress_nat_rule_ids  = [for rules in values(null_resource.nat_rules)[*].triggers : rules.id if rules.mode == "EgressSnat"]
  ingress_nat_rule_ids = [for rules in values(null_resource.nat_rules)[*].triggers : rules.id if rules.mode == "IngressSnat"]

  vpn_gateway_connection = {
    properties = {
      remoteVpnSite = {
        id = azurerm_vpn_site.gamma.id
      }
      vpnLinkConnections = [
        {
          name = "gamma"
          properties = {
            vpnSiteLink                    = { id = azurerm_vpn_site.gamma.link[0].id }
            enableBgp                      = false
            egressNatRules                 = [for nat_rule_id in local.egress_nat_rule_ids : { id = nat_rule_id }]
            ingressNatRules                = [for nat_rule_id in local.ingress_nat_rule_ids : { id = nat_rule_id }]
            sharedKey                      = md5(data.terraform_remote_state.sites.outputs.site["gamma"].resource_group.id) // Just a string - md5 gives a nice predictable one.
            usePolicyBasedTrafficSelectors = false
            vpnConnectionProtocolType      = "IKEv2"
            vpnLinkConnectionMode          = "Default"
          }
        }
      ]
    }

  }
}

resource "azurerm_vpn_site" "gamma" {
  name                = "gamma-site"
  resource_group_name = data.terraform_remote_state.vwan.outputs.resource_group.name
  location            = data.terraform_remote_state.vwan.outputs.resource_group.location
  virtual_wan_id      = data.terraform_remote_state.vwan.outputs.virtual_wan.id

  device_model  = "VNETGW"
  device_vendor = "Azure"
  // address_cidrs = data.terraform_remote_state.sites.outputs.site["beta"].virtual_network.address_space
  address_cidrs = [for prefix in data.terraform_remote_state.sites.outputs.site["gamma"].virtual_network.address_space :
    lookup(local.ingress_mappings, prefix, prefix)
  ]

  link {
    name          = "link1"
    ip_address    = data.terraform_remote_state.sites.outputs.site["gamma"].virtual_network_gateway.ip_address
    speed_in_mbps = 100

    /*
    bgp {
      asn             = data.terraform_remote_state.sites.outputs.site["gamma"].virtual_network_gateway.asn
      peering_address = data.terraform_remote_state.sites.outputs.site["gamma"].virtual_network_gateway.bgp_peering_address
    }
    */
  }
}

resource "null_resource" "nat_rules" {
  // Note that this will currently error if more than one rule is applied due to the REST API behaviour. Wait 10 seconds and reapply
  // Need to add a sleeping loop check for properties.provisioningState to move from Updating to Succeeded
  // az rest --method GET --url ${self.triggers.uri} --query properties.provisioningState --output tsv
  for_each = local.nat_rules

  provisioner "local-exec" {
    command = "az rest --method PUT --url ${self.triggers.uri} --body '${self.triggers.body}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "az rest --method DELETE --url ${self.triggers.uri}"
  }

  triggers = {
    id   = "${local.vpn_gateway_id}/natRules/${each.key}"
    name = each.key
    mode = each.value.properties.mode
    uri  = "https://management.azure.com/${local.vpn_gateway_id}/natRules/${each.key}?api-version=2020-11-01"
    body = jsonencode(each.value)
  }
}

/*
resource "azurerm_vpn_gateway_connection" "gamma" {
  name               = "gamma-connection"
  vpn_gateway_id     = data.terraform_remote_state.vwan.outputs.vpn_gateway.id
  remote_vpn_site_id = azurerm_vpn_site.gamma.id

  vpn_link {
    name             = "link1"
    vpn_site_link_id = azurerm_vpn_site.gamma.link[0].id
    bgp_enabled      = false
    shared_key       = md5(data.terraform_remote_state.sites.outputs.site["gamma"].resource_group.id) // Just a string - md5 gives a nice predictable one.
  }
}
*/

resource "null_resource" "vpn_gateway_connection" {
  depends_on = [
    azurerm_vpn_site.gamma,
    null_resource.nat_rules
  ]

  provisioner "local-exec" {
    command = "az rest --method PUT --url ${self.triggers.uri} --body '${self.triggers.body}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "az rest --method DELETE --url ${self.triggers.uri}"
  }

  triggers = {
    name = "gamma"
    id   = "${local.vpn_gateway_id}/vpnConnections/gamma"
    uri  = "https://management.azure.com/${local.vpn_gateway_id}/vpnConnections/gamma?api-version=2020-11-01"
    body = jsonencode(local.vpn_gateway_connection)
  }
}

//==========================================================================================

// Return connection. Not needed if connecting to a real on prem VPN device.

resource "azurerm_virtual_network_gateway_connection" "gamma-lng0" {
  name                = "gamma-to-hub-vpngw-lng0"
  location            = data.terraform_remote_state.sites.outputs.site["gamma"].resource_group.location
  resource_group_name = data.terraform_remote_state.sites.outputs.site["gamma"].resource_group.name

  type                       = "IPsec"
  virtual_network_gateway_id = data.terraform_remote_state.sites.outputs.site["gamma"].virtual_network_gateway.id
  local_network_gateway_id   = data.terraform_remote_state.vwan.outputs.local_network_gateways[0].id
  enable_bgp                 = false
  shared_key                 = md5(data.terraform_remote_state.sites.outputs.site["gamma"].resource_group.id) // Just a string - md5 gives a nice predictable one.
}
